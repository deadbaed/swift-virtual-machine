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
        do {
            try FileManager.default.createDirectory(atPath: vmBundlePath, withIntermediateDirectories: true)
            VMLogger.shared.info("VM bundle directory created.")
        } catch {
            VMLogger.shared.error("Failed to create VM bundle: \(error)")
            fatalError("Failed to create VM bundle.")
        }
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
        try! virtualMachineConfiguration.validateSaveRestoreSupport()

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

        installationObserver = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { _, change in
            VMLogger.shared.info("Installation progress: \(Int(change.newValue! * 100))%")
        }
    }

    private func createDiskImage() {
        let sizeGiB = 80
        VMLogger.shared.info("Creating disk image at \(diskImageURL.path) (\(sizeGiB) GiB).")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["image", "create", "blank", "--fs", "none", "--format", "ASIF", "--size", "\(sizeGiB)GiB", diskImageURL.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let stderr = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let stderr { VMLogger.shared.error("diskutil: \(stderr)") }
                fatalError("Failed to create disk image (exit code \(process.terminationStatus)).")
            }
            VMLogger.shared.info("Disk image created (\(sizeGiB) GiB).")
        } catch {
            VMLogger.shared.error("Failed to create disk image: \(error.localizedDescription)")
            fatalError("Failed to launch diskutil: \(error.localizedDescription)")
        }
    }
}

#endif
