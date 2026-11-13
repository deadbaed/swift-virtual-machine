#!/usr/bin/env bash
# Get the IP address of the swift-virtual-machine NAT guest by its MAC address.

VM_MAC_ADDRESS="${VM_MAC_ADDRESS:-d6:a7:58:8e:78:d4}"
LEASE_FILE="${LEASE_FILE:-/var/db/dhcpd_leases}"

if [[ ! -r "$LEASE_FILE" ]]; then
    echo "Error: cannot read DHCP lease file: $LEASE_FILE" >&2
    exit 1
fi

awk -v mac="$VM_MAC_ADDRESS" '
BEGIN {
    target_mac = tolower(mac)
}
/^\{/ {
    in_block = 1
    block_ip = ""
    block_mac = ""
    next
}
/^\}/ {
    in_block = 0
    if (block_mac == target_mac && block_ip != "") {
        print block_ip
        found = 1
    }
    next
}
in_block && /ip_address=/ {
    sub(/^[^=]*=/, "")
    block_ip = $0
    next
}
in_block && /hw_address=/ {
    sub(/^[^=]*=/, "")
    split($0, parts, ",")
    if (length(parts) >= 2) {
        block_mac = tolower(parts[2])
    }
    next
}
END {
    if (!found) {
        exit 1
    }
}
' "$LEASE_FILE"
