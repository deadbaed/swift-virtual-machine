## Troubleshooting

If you exclusively run your mac over ssh, after a reboot you will not be able to launch virtual machines, with this error:

```
swift_virtual_machine/MacOSVirtualMachineRunner.swift:106: Fatal error: Virtual machine failed to start with Error Domain=VZErrorDomain Code=-9 "The virtual machine encountered a security error." UserInfo={NSLocalizedFailure=Unable to access security information., NSLocalizedFailureReason=The virtual machine encountered a security error., NSUnderlyingError=0x7afef44660 {Error Domain=NSPOSIXErrorDomain Code=22 "Invalid argument" UserInfo={NSLocalizedFailureReason=Failed to get current host key., NSUnderlyingError=0x7afef44630 {Error Domain=NSPOSIXErrorDomain Code=22 "Invalid argument" UserInfo={NSLocalizedFailureReason=Failed to create new HostKey., NSUnderlyingError=0x7afef44600 {Error Domain=NSPOSIXErrorDomain Code=22 "Invalid argument" UserInfo=0x7aff050cc0 (not displayed)}}}}}}
[1]    2533 trace trap  ./result/bin/swift-virtual-machine run
```

Unlock the keyring with:
```shell
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

You can now start virtual machines again.
