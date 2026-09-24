import Foundation
@preconcurrency import Virtualization

#if arch(arm64)

struct MacOSVirtualMachineConfigurationHelper {
    static func computeCPUCount() -> Int {
        let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
        var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
        virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        return virtualCPUCount
    }

    static func computeMemorySize() -> UInt64 {
        var memorySize = (12 * 1024 * 1024 * 1024) as UInt64
        memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        return memorySize
    }

    static func createBootLoader() -> VZMacOSBootLoader {
        return VZMacOSBootLoader()
    }

    static func createBlockDeviceConfiguration() -> VZVirtioBlockDeviceConfiguration {
        guard let diskImageAttachment = try? VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false) else {
            fatalError("Failed to create Disk image.")
        }
        let disk = VZVirtioBlockDeviceConfiguration(attachment: diskImageAttachment)
        return disk
    }

    static func createGraphicsDeviceConfiguration() -> VZMacGraphicsDeviceConfiguration {
        let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
        graphicsConfiguration.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)
        ]
        return graphicsConfiguration
    }

    static func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        // TODO: optional mac address as parameter
        networkDevice.macAddress = VZMACAddress(string: "d6:a7:58:8e:78:d4")!
        let networkAttachment = VZNATNetworkDeviceAttachment()
        networkDevice.attachment = networkAttachment
        return networkDevice
    }

    static func createSoundDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let audioConfiguration = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        audioConfiguration.streams = [inputStream, outputStream]
        return audioConfiguration
    }

    static func createPointingDeviceConfiguration() -> VZPointingDeviceConfiguration {
        return VZMacTrackpadConfiguration()
    }

    static func createKeyboardConfiguration() -> VZKeyboardConfiguration {
        // // TODO: remove as this only for macos 27
        // if #available(macOS 14.0, *) {
        //     return VZMacKeyboardConfiguration()
        // } else {
        //     return VZUSBKeyboardConfiguration()
        // }
        return VZMacKeyboardConfiguration()
    }
}

#endif
