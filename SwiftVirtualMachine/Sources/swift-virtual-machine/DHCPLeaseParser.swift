import Foundation

#if arch(arm64)

struct DHCPLeaseParser {
    /// Looks up the IP address assigned to a given MAC address in `/var/db/dhcpd_leases`.
    /// This is the lease file used by macOS for VZNATNetworkDeviceAttachment VMs.
    static func ipAddress(forMACAddress macAddress: String) -> String? {
        let leaseFilePath = "/var/db/dhcpd_leases"
        guard let content = try? String(contentsOfFile: leaseFilePath, encoding: .utf8) else {
            return nil
        }

        let targetMAC = macAddress.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = content.components(separatedBy: "}")

        for block in blocks {
            let lines = block.components(separatedBy: .newlines)
            var currentIP: String?
            var currentMAC: String?

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ip_address=") {
                    currentIP = String(trimmed.dropFirst("ip_address=".count))
                } else if trimmed.hasPrefix("hw_address=") {
                    let value = String(trimmed.dropFirst("hw_address=".count))
                    let components = value.components(separatedBy: ",")
                    if components.count == 2 {
                        currentMAC = components[1].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }

            if let ip = currentIP, let mac = currentMAC, mac == targetMAC {
                return ip
            }
        }

        return nil
    }
}

#endif
