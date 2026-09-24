import Foundation

#if arch(arm64)

func printUsage() {
    print("""
Usage: swift-virtual-machine <command> [options]

Commands:
  install <ipsw-path>    Install macOS from an IPSW file
  run                    Launch the virtual machine
""")
}

if CommandLine.arguments.count < 2 {
    printUsage()
    exit(-1)
}

let command = CommandLine.arguments[1]

switch command {
case "install":
    guard CommandLine.arguments.count == 3 else {
        print("Usage: swift-virtual-machine install <ipsw-path>")
        exit(-1)
    }
    let ipswPath = CommandLine.arguments[2]
    let ipswURL = URL(fileURLWithPath: ipswPath)
    guard ipswURL.isFileURL else {
        fatalError("The provided IPSW path is not a valid file URL.")
    }

    let installer = MacOSVirtualMachineInstaller()
    installer.setUpVirtualMachineArtifacts()
    installer.installMacOS(ipswURL: ipswURL)

    dispatchMain()

case "run":
    let runner = MacOSVirtualMachineRunner()
    runner.run()

default:
    print("Unknown command: \(command)")
    printUsage()
    exit(-1)
}

#else

NSLog("This tool can only be run on Apple Silicon Macs.")
exit(-1)

#endif
