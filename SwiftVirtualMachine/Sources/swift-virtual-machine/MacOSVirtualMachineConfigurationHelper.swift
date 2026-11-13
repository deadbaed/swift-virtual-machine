import Foundation
@preconcurrency import Virtualization

#if arch(arm64)

struct MacOSVirtualMachineConfigurationHelper {
    static func computeCPUCount() -> Int {
        let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
        var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
        virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        VMLogger.shared.info("Computed VM CPU count: \(virtualCPUCount) (host has \(totalAvailableCPUs))")
        return virtualCPUCount
    }

    static func computeMemorySize() -> UInt64 {
        var memorySize = (12 * 1024 * 1024 * 1024) as UInt64
        memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        VMLogger.shared.info("Computed VM memory size: \(formatBytes(memorySize))")
        return memorySize
    }

    static func createBootLoader() -> VZMacOSBootLoader {
        VMLogger.shared.debug("Creating macOS boot loader.")
        return VZMacOSBootLoader()
    }

    static func createBlockDeviceConfiguration() -> VZVirtioBlockDeviceConfiguration {
        VMLogger.shared.info("Registering storage device: \(diskImageURL.path)")
        guard let diskImageAttachment = try? VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false) else {
            fatalError("Failed to create Disk image.")
        }
        let disk = VZVirtioBlockDeviceConfiguration(attachment: diskImageAttachment)
        return disk
    }

    static func createGraphicsDeviceConfiguration() -> VZMacGraphicsDeviceConfiguration {
        let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
        let display = VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)
        graphicsConfiguration.displays = [display]
        VMLogger.shared.info("Registering graphics device: \(display.widthInPixels)x\(display.heightInPixels) @ \(display.pixelsPerInch) PPI")
        return graphicsConfiguration
    }

    static func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
        let macAddress = "d6:a7:58:8e:78:d4"
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.macAddress = VZMACAddress(string: macAddress)!
        let networkAttachment = VZNATNetworkDeviceAttachment()
        networkDevice.attachment = networkAttachment
        VMLogger.shared.info("Registering network device: MAC \(macAddress), attachment NAT")
        return networkDevice
    }

    static func createSoundDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let audioConfiguration = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        audioConfiguration.streams = [inputStream, outputStream]
        VMLogger.shared.info("Registering audio device: input + output streams")
        return audioConfiguration
    }

    static func createPointingDeviceConfiguration() -> VZPointingDeviceConfiguration {
        VMLogger.shared.debug("Registering pointing device: Mac trackpad.")
        return VZMacTrackpadConfiguration()
    }

    static func createKeyboardConfiguration() -> VZKeyboardConfiguration {
        VMLogger.shared.debug("Registering keyboard: Mac keyboard.")
        return VZMacKeyboardConfiguration()
    }
}

#endif
