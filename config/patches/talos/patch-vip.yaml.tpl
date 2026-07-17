machine:
  network:
    interfaces:
      - interface: ${interface}
        dhcp: true
        vip:
          ip: ${vip_address}
