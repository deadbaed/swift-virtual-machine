import Foundation
@preconcurrency import Virtualization

#if arch(arm64)

class MacOSVirtualMachineDelegate: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        VMLogger.shared.error("Virtual machine did stop with error: \(error.localizedDescription)")
        exit(-1)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        VMLogger.shared.info("Guest did stop virtual machine.")
        exit(0)
    }
}

final class MacOSVirtualMachineInstaller: NSObject, @unchecked Sendable {
    private var installationObserver: NSKeyValueObservation?
    private var virtualMachine: VZVirtualMachine!
    private var virtualMachineResponder: MacOSVirtualMachineDelegate?

    public func setUpVirtualMachineArtifacts() {
        VMLogger.shared.info("Creating VM bundle at \(vmBundlePath).")
        createVMBundle()
    }

    public func installMacOS(ipswURL: URL) {
        VMLogger.shared.info("Attempting to install from IPSW at \(ipswURL.path).")
        VZMacOSRestoreImage.load(from: ipswURL, completionHandler: { [self] (result: Result<VZMacOSRestoreImage, Error>) in
            switch result {
            case let .failure(error):
                VMLogger.shared.error("Failed to load restore image: \(error.localizedDescription)")
                fatalError(error.localizedDescription)
            case let .success(restoreImage):
                VMLogger.shared.info("Restore image loaded successfully.")
                installMacOS(restoreImage: restoreImage)
            }
        })
    }

    private func installMacOS(restoreImage: VZMacOSRestoreImage) {
        guard let macOSConfiguration = restoreImage.mostFeaturefulSupportedConfiguration else {
            fatalError("No supported configuration available.")
        }
        VMLogger.shared.info("Selected macOS configuration: minimum CPUs=\(macOSConfiguration.minimumSupportedCPUCount), minimum memory=\(formatBytes(macOSConfiguration.minimumSupportedMemorySize))")

        if !macOSConfiguration.hardwareModel.isSupported {
            fatalError("macOSConfiguration configuration isn't supported on the current host.")
        }

        DispatchQueue.main.async { [self] in
            setupVirtualMachine(macOSConfiguration: macOSConfiguration)
            startInstallation(restoreImageURL: restoreImage.url)
        }
    }

    private func createMacPlatformConfiguration(macOSConfiguration: VZMacOSConfigurationRequirements) -> VZMacPlatformConfiguration {
        let macPlatformConfiguration = VZMacPlatformConfiguration()

        do {
            let auxiliaryStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxiliaryStorageURL,
                hardwareModel: macOSConfiguration.hardwareModel,
                options: [VZMacAuxiliaryStorage.InitializationOptions.allowOverwrite]
            )
            macPlatformConfiguration.auxiliaryStorage = auxiliaryStorage
            VMLogger.shared.info("Created auxiliary storage at \(auxiliaryStorageURL.path).")
        } catch {
            VMLogger.shared.error("Failed to create auxiliary storage: \(error)")
            fatalError("Failed to create auxiliary storage: \(error)")
        }

        macPlatformConfiguration.hardwareModel = macOSConfiguration.hardwareModel
        macPlatformConfiguration.machineIdentifier = VZMacMachineIdentifier()

        do {
            try macPlatformConfiguration.hardwareModel.dataRepresentation.write(to: hardwareModelURL)
            try macPlatformConfiguration.machineIdentifier.dataRepresentation.write(to: machineIdentifierURL)
            VMLogger.shared.info("Saved hardware model (\(macPlatformConfiguration.hardwareModel.dataRepresentation.count) bytes) and machine identifier (\(macPlatformConfiguration.machineIdentifier.dataRepresentation.count) bytes).")
        } catch {
            VMLogger.shared.error("Failed to save platform artifacts: \(error)")
            fatalError("Failed to write platform configuration files: \(error)")
        }

        return macPlatformConfiguration
    }

    private func setupVirtualMachine(macOSConfiguration: VZMacOSConfigurationRequirements) {
        VMLogger.shared.info("Configuring virtual machine for installation.")
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()

        virtualMachineConfiguration.platform = createMacPlatformConfiguration(macOSConfiguration: macOSConfiguration)
        virtualMachineConfiguration.cpuCount = MacOSVirtualMachineConfigurationHelper.computeCPUCount()
        if virtualMachineConfiguration.cpuCount < macOSConfiguration.minimumSupportedCPUCount {
            fatalError("CPUCount isn't supported by the macOS configuration.")
        }

        virtualMachineConfiguration.memorySize = MacOSVirtualMachineConfigurationHelper.computeMemorySize()
        if virtualMachineConfiguration.memorySize < macOSConfiguration.minimumSupportedMemorySize {
            fatalError("memorySize isn't supported by the macOS configuration.")
        }

        createDiskImage()

        virtualMachineConfiguration.bootLoader = MacOSVirtualMachineConfigurationHelper.createBootLoader()

        virtualMachineConfiguration.audioDevices = [MacOSVirtualMachineConfigurationHelper.createSoundDeviceConfiguration()]
        virtualMachineConfiguration.graphicsDevices = [MacOSVirtualMachineConfigurationHelper.createGraphicsDeviceConfiguration()]
        virtualMachineConfiguration.networkDevices = [MacOSVirtualMachineConfigurationHelper.createNetworkDeviceConfiguration()]
        virtualMachineConfiguration.storageDevices = [MacOSVirtualMachineConfigurationHelper.createBlockDeviceConfiguration()]

        virtualMachineConfiguration.pointingDevices = [MacOSVirtualMachineConfigurationHelper.createPointingDeviceConfiguration()]
        virtualMachineConfiguration.keyboards = [MacOSVirtualMachineConfigurationHelper.createKeyboardConfiguration()]

        VMLogger.shared.info("Validating installation VM configuration.")
        try! virtualMachineConfiguration.validate()

        if #available(macOS 14.0, *) {
            try! virtualMachineConfiguration.validateSaveRestoreSupport()
        }

        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
        virtualMachineResponder = MacOSVirtualMachineDelegate()
        virtualMachine.delegate = virtualMachineResponder
        VMLogger.shared.info("Virtual machine configured and ready for installation.")
    }

    private func startInstallation(restoreImageURL: URL) {
        let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: restoreImageURL)

        VMLogger.shared.info("Starting installation from \(restoreImageURL.path).")
        installer.install(completionHandler: { (result: Result<Void, Error>) in
            if case let .failure(error) = result {
                VMLogger.shared.error("Installation failed: \(error.localizedDescription)")
                fatalError(error.localizedDescription)
            } else {
                VMLogger.shared.info("Installation succeeded.")
            }
        })

        installationObserver = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { (progress, change) in
            var percentageProgress = change.newValue! * 100
            percentageProgress.round(.towardZero)

            VMLogger.shared.info("Installation progress: \(Int(percentageProgress))%")
        }
    }

    private func createVMBundle() {
        do {
            try FileManager.default.createDirectory(atPath: vmBundlePath, withIntermediateDirectories: true)
            VMLogger.shared.info("VM bundle directory created.")
        } catch {
            VMLogger.shared.error("Failed to create VM bundle: \(error)")
            fatalError("Failed to create VM bundle.")
        }
    }

    @available(macOS 16.0, *)
    private func createASIFDiskImage() {
        VMLogger.shared.info("Creating ASIF disk image at \(diskImageURL.path).")
        do {
            let process = try Process.run(
                URL(fileURLWithPath: "/usr/sbin/diskutil"),
                arguments: ["image", "create", "blank", "--fs", "none", "--format", "ASIF", "--size", "80GiB", diskImageURL.path]
            )
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                fatalError("Failed to create the disk image.")
            }
            VMLogger.shared.info("ASIF disk image created.")
        } catch {
            VMLogger.shared.error("Failed to create ASIF disk image: \(error.localizedDescription)")
            fatalError("Failed to launch diskutil: \(error.localizedDescription)")
        }
    }

    private func createRAWDiskImage() {
        VMLogger.shared.info("Creating blank RAW disk image at \(diskImageURL.path) (128 GiB).")
        let diskFd = open(diskImageURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        if diskFd == -1 {
            fatalError("Cannot create disk image.")
        }

        var result = ftruncate(diskFd, 128 * 1024 * 1024 * 1024)
        if result != 0 {
            fatalError("ftruncate() failed.")
        }

        result = close(diskFd)
        if result != 0 {
            fatalError("Failed to close the disk image.")
        }
        VMLogger.shared.info("RAW disk image created.")
    }

    private func createDiskImage() {
        if #available(macOS 16.0, *) {
            createASIFDiskImage()
        } else {
            createRAWDiskImage()
        }
    }
}

#endif
