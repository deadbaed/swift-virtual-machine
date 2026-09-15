import Foundation

#if arch(arm64)

let installer = MacOSVirtualMachineInstaller()

// TODO: parse CLI arguments
// TODO: - create VM: ipsw and a path to store the VM bundle, optionally VM metadata
// TODO: - launch VM: path to VM bundle, needs to contain the file with VM metadata

if CommandLine.arguments.count == 2 {
    let ipswPath = CommandLine.arguments[1]
    let ipswURL = URL(fileURLWithPath: ipswPath)
    guard ipswURL.isFileURL else {
        fatalError("The provided IPSW path is not a valid file URL.")
    }

    installer.setUpVirtualMachineArtifacts()
    installer.installMacOS(ipswURL: ipswURL)

    dispatchMain()
} else {
    NSLog("Invalid argument. Please provide the path to an IPSW file.")
    exit(-1)
}

#else

// TODO: remove all if arch(arm64), since macos 27 is only for arm64
NSLog("This tool can only be run on Apple Silicon Macs.")
exit(-1)

#endif
