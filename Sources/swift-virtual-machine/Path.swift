import Foundation

let vmBundlePath = "./swift-virtual-machine.bundle/"
let vmBundleURL = URL(fileURLWithPath: vmBundlePath)
let auxiliaryStorageURL = vmBundleURL.appendingPathComponent("AuxiliaryStorage")
let diskImageURL = vmBundleURL.appendingPathComponent("Disk.img")
let hardwareModelURL = vmBundleURL.appendingPathComponent("HardwareModel")
let machineIdentifierURL = vmBundleURL.appendingPathComponent("MachineIdentifier")
let restoreImageURL = vmBundleURL.appendingPathComponent("RestoreImage.ipsw")
let saveFileURL = vmBundleURL.appendingPathComponent("SaveFile.vzvmsave")
