import Foundation
@preconcurrency import Virtualization

#if arch(arm64)

class MacOSVirtualMachineRunner: NSObject {
    private static let virtualMachineMACAddress = "d6:a7:58:8e:78:d4"
    private static let virtualMachineUser = "user"
    private static let virtualMachinePassword = "password"
    private var virtualMachine: VZVirtualMachine!
    private var virtualMachineConfiguration: VZVirtualMachineConfiguration?
    private var virtualMachineResponder: MacOSVirtualMachineDelegate?
    private var ipAddressDispatchSource: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var isShuttingDown = false
    private var provisioningScriptPath: String?

    func run(provisioningScriptPath: String? = nil) {
        self.provisioningScriptPath = provisioningScriptPath
        VMLogger.shared.info("VM runner started.")
        DispatchQueue.main.async { [self] in
            createVirtualMachine()
            logHardwareInfo()
            virtualMachineResponder = MacOSVirtualMachineDelegate()
            virtualMachine.delegate = virtualMachineResponder

            setupSignalHandlers()

            if #available(macOS 14.0, *) {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: saveFileURL.path) {
                    VMLogger.shared.info("Found saved VM state at \(saveFileURL.path); restoring.")
                    restoreVirtualMachine()
                } else {
                    VMLogger.shared.info("No saved VM state found; starting fresh.")
                    startVirtualMachine()
                }
            } else {
                startVirtualMachine()
            }
        }

        dispatchMain()
    }

    // MARK: - Platform Configuration

    private func createMacPlatform() -> VZMacPlatformConfiguration {
        let macPlatform = VZMacPlatformConfiguration()
        VMLogger.shared.info("Loading auxiliary storage from \(auxiliaryStorageURL.path)")

        let auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxiliaryStorageURL)
        macPlatform.auxiliaryStorage = auxiliaryStorage

        if !FileManager.default.fileExists(atPath: vmBundlePath) {
            fatalError("Missing Virtual Machine Bundle at \(vmBundlePath). Run the install command first to create it.")
        }

        guard let hardwareModelData = try? Data(contentsOf: hardwareModelURL) else {
            fatalError("Failed to retrieve hardware model data.")
        }

        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            fatalError("Failed to create hardware model.")
        }

        if !hardwareModel.isSupported {
            fatalError("The hardware model isn't supported on the current host")
        }
        macPlatform.hardwareModel = hardwareModel
        VMLogger.shared.info("Loaded hardware model (\(hardwareModelData.count) bytes).")

        guard let machineIdentifierData = try? Data(contentsOf: machineIdentifierURL) else {
            fatalError("Failed to retrieve machine identifier data.")
        }

        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            fatalError("Failed to create machine identifier.")
        }
        macPlatform.machineIdentifier = machineIdentifier
        VMLogger.shared.info("Loaded machine identifier (\(machineIdentifierData.count) bytes).")

        return macPlatform
    }

    // MARK: - Virtual Machine Creation

    private func createVirtualMachine() {
        VMLogger.shared.info("Building virtual machine configuration.")
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()

        virtualMachineConfiguration.platform = createMacPlatform()
        virtualMachineConfiguration.bootLoader = MacOSVirtualMachineConfigurationHelper.createBootLoader()
        virtualMachineConfiguration.cpuCount = MacOSVirtualMachineConfigurationHelper.computeCPUCount()
        virtualMachineConfiguration.memorySize = MacOSVirtualMachineConfigurationHelper.computeMemorySize()

        virtualMachineConfiguration.audioDevices = [MacOSVirtualMachineConfigurationHelper.createSoundDeviceConfiguration()]
        virtualMachineConfiguration.graphicsDevices = [MacOSVirtualMachineConfigurationHelper.createGraphicsDeviceConfiguration()]
        virtualMachineConfiguration.networkDevices = [MacOSVirtualMachineConfigurationHelper.createNetworkDeviceConfiguration()]
        virtualMachineConfiguration.storageDevices = [MacOSVirtualMachineConfigurationHelper.createBlockDeviceConfiguration()]

        virtualMachineConfiguration.pointingDevices = [MacOSVirtualMachineConfigurationHelper.createPointingDeviceConfiguration()]
        virtualMachineConfiguration.keyboards = [MacOSVirtualMachineConfigurationHelper.createKeyboardConfiguration()]

        VMLogger.shared.info("Validating virtual machine configuration.")
        try! virtualMachineConfiguration.validate()

        if #available(macOS 14.0, *) {
            VMLogger.shared.info("Validating save/restore support.")
            try! virtualMachineConfiguration.validateSaveRestoreSupport()
        }

        VMLogger.shared.info("Creating VZVirtualMachine instance.")
        self.virtualMachineConfiguration = virtualMachineConfiguration
        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
    }

    // MARK: - VM Lifecycle

    private func startVirtualMachine() {
        VMLogger.shared.info("Starting virtual machine.")
        if #available(macOS 27.0, *) {
            let startOptions = createMacOSStartOptions()
            virtualMachine.start(options: startOptions, completionHandler: { (error) in
                if let error {
                    VMLogger.shared.error("Virtual machine failed to start with \(error)")
                    fatalError("Virtual machine failed to start with \(error)")
                } else {
                    VMLogger.shared.info("Virtual machine started successfully.")
                    self.startPollingForIPAddress()
                }
            })
        } else {
            virtualMachine.start(completionHandler: { (result) in
                if case let .failure(error) = result {
                    VMLogger.shared.error("Virtual machine failed to start with \(error)")
                    fatalError("Virtual machine failed to start with \(error)")
                } else {
                    VMLogger.shared.info("Virtual machine started successfully.")
                    self.startPollingForIPAddress()
                }
            })
        }
    }

    private func startPollingForIPAddress() {
        // Poll the host DHCP lease file until the VM receives an IP address.
        VMLogger.shared.info("Polling for virtual machine IP address...")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let ipAddress = DHCPLeaseParser.ipAddress(forMACAddress: Self.virtualMachineMACAddress) {
                VMLogger.shared.info("Virtual machine IP address: \(ipAddress)")
                timer.cancel()
                self.ipAddressDispatchSource = nil
                self.beginProvisioning(ipAddress: ipAddress)
            }
        }
        ipAddressDispatchSource = timer
        timer.resume()
    }

    private func beginProvisioning(ipAddress: String) {
        guard let scriptPath = provisioningScriptPath else {
            VMLogger.shared.info("No provisioning script configured; skipping post-boot provisioning.")
            return
        }

        let markerPath = provisioningMarkerURL.path
        if FileManager.default.fileExists(atPath: markerPath) {
            VMLogger.shared.info("Provisioning marker exists at \(markerPath); skipping post-boot provisioning.")
            return
        }

        VMLogger.shared.info("Starting post-boot provisioning with script \(scriptPath) on \(ipAddress).")
        VMLogger.shared.info("Waiting 20 seconds for SSH to become available...")
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.attemptProvisioning(ipAddress: ipAddress, scriptPath: scriptPath, retriesLeft: 60)
        }
    }

    private func attemptProvisioning(ipAddress: String, scriptPath: String, retriesLeft: Int) {
        do {
            let result = try SSHProvisioner.runScript(
                host: ipAddress,
                username: Self.virtualMachineUser,
                password: Self.virtualMachinePassword,
                scriptPath: scriptPath
            )
            VMLogger.shared.info("Provisioning finished with exit code \(result.exitStatus).")
            if !result.stdout.isEmpty {
                VMLogger.shared.info("Provisioning stdout:\n\(result.stdout)")
            }
            if !result.stderr.isEmpty {
                VMLogger.shared.warn("Provisioning stderr:\n\(result.stderr)")
            }

            if result.exitStatus == 0 {
                createProvisioningMarker()
            } else {
                VMLogger.shared.error("Provisioning script exited with status \(result.exitStatus); marker not written.")
            }
        } catch {
            guard retriesLeft > 0 else {
                VMLogger.shared.error("Provisioning failed after retries: \(error)")
                return
            }
            VMLogger.shared.info("Provisioning attempt failed: \(error). Retrying in 5 seconds...")
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.attemptProvisioning(ipAddress: ipAddress, scriptPath: scriptPath, retriesLeft: retriesLeft - 1)
            }
        }
    }

    private func createProvisioningMarker() {
        let markerPath = provisioningMarkerURL.path
        guard FileManager.default.createFile(atPath: markerPath, contents: Data(), attributes: nil) else {
            VMLogger.shared.warn("Failed to create provisioning marker at \(markerPath).")
            return
        }
        VMLogger.shared.info("Created provisioning marker at \(markerPath).")
    }

    @available(macOS 27.0, *)
    private func createMacOSStartOptions() -> VZMacOSVirtualMachineStartOptions {
        let startOptions = VZMacOSVirtualMachineStartOptions()
        let provisioningOptions = VZMacGuestProvisioningOptions()
        provisioningOptions.fullName = Self.virtualMachineUser
        provisioningOptions.username = Self.virtualMachineUser
        provisioningOptions.password = Self.virtualMachinePassword
        provisioningOptions.enablesRemoteLogin = true
        VMLogger.shared.info("Configuring guest provisioning: user='\(Self.virtualMachineUser)', remoteLogin=\(provisioningOptions.enablesRemoteLogin)")
        do {
            try startOptions.setGuestProvisioning(provisioningOptions)
        } catch {
            VMLogger.shared.error("Failed to set guest provisioning options: \(error)")
            fatalError("Failed to set guest provisioning options: \(error)")
        }
        return startOptions
    }

    private func resumeVirtualMachine() {
        VMLogger.shared.info("Resuming virtual machine.")
        virtualMachine.resume(completionHandler: { (result) in
            if case let .failure(error) = result {
                VMLogger.shared.error("Virtual machine failed to resume with \(error)")
                fatalError("Virtual machine failed to resume with \(error)")
            } else {
                VMLogger.shared.info("Virtual machine resumed successfully.")
            }
        })
    }

    @available(macOS 14.0, *)
    private func restoreVirtualMachine() {
        VMLogger.shared.info("Restoring virtual machine state from \(saveFileURL.path).")
        virtualMachine.restoreMachineStateFrom(url: saveFileURL, completionHandler: { [self] (error) in
            let fileManager = FileManager.default
            try! fileManager.removeItem(at: saveFileURL)

            if error == nil {
                self.resumeVirtualMachine()
            } else {
                VMLogger.shared.warn("Failed to restore VM state: \(error!). Starting fresh.")
                self.startVirtualMachine()
            }
        })
    }

    @available(macOS 14.0, *)
    private func saveVirtualMachine(completionHandler: @escaping () -> Void) {
        VMLogger.shared.info("Saving virtual machine state to \(saveFileURL.path).")
        virtualMachine.saveMachineStateTo(url: saveFileURL, completionHandler: { (error) in
            guard error == nil else {
                VMLogger.shared.error("Virtual machine failed to save with \(error!)")
                fatalError("Virtual machine failed to save with \(error!)")
            }
            VMLogger.shared.info("Virtual machine state saved.")
            completionHandler()
        })
    }

    @available(macOS 14.0, *)
    private func pauseAndSaveVirtualMachine(completionHandler: @escaping () -> Void) {
        VMLogger.shared.info("Pausing virtual machine before save.")
        virtualMachine.pause(completionHandler: { (result) in
            if case let .failure(error) = result {
                VMLogger.shared.error("Virtual machine failed to pause with \(error)")
                fatalError("Virtual machine failed to pause with \(error)")
            }
            VMLogger.shared.info("Virtual machine paused.")
            self.saveVirtualMachine(completionHandler: completionHandler)
        })
    }

    // MARK: - Signal Handling

    private func setupSignalHandlers() {
        VMLogger.shared.info("Installing signal handlers (SIGINT, SIGTERM).")
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in
            self?.handleShutdown()
        }
        signal(SIGINT, SIG_IGN)
        intSource.resume()
        signalSources.append(intSource)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in
            self?.handleShutdown()
        }
        signal(SIGTERM, SIG_IGN)
        termSource.resume()
        signalSources.append(termSource)
    }

    private func handleShutdown() {
        guard !isShuttingDown else {
            VMLogger.shared.info("Shutdown already in progress; ignoring signal.")
            return
        }
        isShuttingDown = true
        VMLogger.shared.info("Shutdown signal received; handling graceful shutdown.")

        guard virtualMachine.state == .running else {
            VMLogger.shared.info("VM is not running; exiting.")
            exit(0)
        }

        VMLogger.shared.info("Requesting graceful VM shutdown...")
        do {
            try virtualMachine.requestStop()
            VMLogger.shared.info("Graceful shutdown requested; waiting for guest to stop.")
            // Safety net: if the guest ignores the request, force stop after 30s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
                guard let self = self else { return }
                guard self.virtualMachine.state != .stopped else { return }
                VMLogger.shared.warn("Guest did not stop in time; forcing stop.")
                self.forceStopVirtualMachine()
            }
            return
        } catch {
            VMLogger.shared.warn("Graceful shutdown request failed: \(error.localizedDescription)")
        }

        saveStateOrExit()
    }

    private func saveStateOrExit() {
        if #available(macOS 14.0, *) {
            VMLogger.shared.info("Pausing and saving VM state before exit.")
            pauseAndSaveVirtualMachine(completionHandler: {
                VMLogger.shared.info("Shutdown complete (saved state).")
                exit(0)
            })
        } else {
            VMLogger.shared.info("Exiting without saving state.")
            exit(0)
        }
    }

    private func forceStopVirtualMachine() {
        VMLogger.shared.info("Force stopping virtual machine.")
        virtualMachine.stop(completionHandler: { error in
            if let error {
                VMLogger.shared.error("Force stop failed: \(error)")
            } else {
                VMLogger.shared.info("Virtual machine force stopped.")
            }
            exit(0)
        })
    }

    // MARK: - Hardware Info

    private func logHardwareInfo() {
        let hostCPUs = ProcessInfo.processInfo.processorCount
        let hostMemory = ProcessInfo.processInfo.physicalMemory
        VMLogger.shared.info("Host hardware: \(hostCPUs) CPUs, \(formatBytes(hostMemory)) RAM")

        if let config = virtualMachineConfiguration {
            VMLogger.shared.info("VM configuration: \(config.cpuCount) vCPUs, \(formatBytes(config.memorySize)) RAM")
            VMLogger.shared.info("VM devices registered: audio=\(config.audioDevices.count), graphics=\(config.graphicsDevices.count), network=\(config.networkDevices.count), storage=\(config.storageDevices.count), pointing=\(config.pointingDevices.count), keyboards=\(config.keyboards.count)")
        }
    }
}

#endif
