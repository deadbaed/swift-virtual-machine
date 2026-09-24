import Foundation
@preconcurrency import Virtualization

#if arch(arm64)

class MacOSVirtualMachineDelegate: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        NSLog("Virtual machine did stop with error: \(error.localizedDescription)")
        exit(-1)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        NSLog("Guest did stop virtual machine.")
        exit(0)
    }
}

final class MacOSVirtualMachineInstaller: NSObject, @unchecked Sendable {
    private var installationObserver: NSKeyValueObservation?
    private var virtualMachine: VZVirtualMachine!
    private var virtualMachineResponder: MacOSVirtualMachineDelegate?

    public func setUpVirtualMachineArtifacts() {
        createVMBundle()
    }

    public func installMacOS(ipswURL: URL) {
        NSLog("Attempting to install from IPSW at \(ipswURL).")
        VZMacOSRestoreImage.load(from: ipswURL, completionHandler: { [self] (result: Result<VZMacOSRestoreImage, Error>) in
            switch result {
            case let .failure(error):
                fatalError(error.localizedDescription)
            case let .success(restoreImage):
                installMacOS(restoreImage: restoreImage)
            }
        })
    }

    private func installMacOS(restoreImage: VZMacOSRestoreImage) {
        guard let macOSConfiguration = restoreImage.mostFeaturefulSupportedConfiguration else {
            fatalError("No supported configuration available.")
        }

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
        } catch {
            fatalError("Failed to create auxiliary storage: \(error)")
        }

        macPlatformConfiguration.hardwareModel = macOSConfiguration.hardwareModel
        macPlatformConfiguration.machineIdentifier = VZMacMachineIdentifier()

        try! macPlatformConfiguration.hardwareModel.dataRepresentation.write(to: hardwareModelURL)
        try! macPlatformConfiguration.machineIdentifier.dataRepresentation.write(to: machineIdentifierURL)

        return macPlatformConfiguration
    }

    private func setupVirtualMachine(macOSConfiguration: VZMacOSConfigurationRequirements) {
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

        try! virtualMachineConfiguration.validate()

        if #available(macOS 14.0, *) {
            try! virtualMachineConfiguration.validateSaveRestoreSupport()
        }

        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
        virtualMachineResponder = MacOSVirtualMachineDelegate()
        virtualMachine.delegate = virtualMachineResponder
    }

    private func startInstallation(restoreImageURL: URL) {
        let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: restoreImageURL)

        NSLog("Starting installation.")
        installer.install(completionHandler: { (result: Result<Void, Error>) in
            if case let .failure(error) = result {
                fatalError(error.localizedDescription)
            } else {
                NSLog("Installation succeeded.")
            }
        })

        installationObserver = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { (progress, change) in
            var percentageProgress = change.newValue! * 100
            percentageProgress.round(.towardZero)

            NSLog("Installation progress: \(Int(percentageProgress)).")
            // NSLog("Installation progress: \(change.newValue! * 100).")
        }
    }

    private func createVMBundle() {
        do {
            try FileManager.default.createDirectory(atPath: vmBundlePath, withIntermediateDirectories: true)
        } catch {
            fatalError("Failed to create VM bundle.")
        }
    }

    @available(macOS 16.0, *)
    private func createASIFDiskImage() {
        do {
            let process = try Process.run(
                URL(fileURLWithPath: "/usr/sbin/diskutil"),
                arguments: ["image", "create", "blank", "--fs", "none", "--format", "ASIF", "--size", "128GiB", diskImageURL.path]
            )
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                fatalError("Failed to create the disk image.")
            }
        } catch {
            fatalError("Failed to launch diskutil: \(error.localizedDescription)")
        }
    }

    private func createRAWDiskImage() {
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
