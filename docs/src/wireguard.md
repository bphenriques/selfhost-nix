# WireGuard VPN

An opt-in WireGuard server with a per-user device registry and in-person client provisioning. Like
`storage.smb`, it is gated — importing the module changes nothing until `selfhost.vpn.wireguard.enable`.

## Provisioning model

The server holds the authority: it generates each client's keypair (clients never submit their own).
To onboard a device, run `wg-manage show <name>`, which renders a QR code to scan directly onto the
device in person — there is no email or other out-of-band key exchange. Devices are declared under
`users.<name>.services.wireguard.devices`.

## LAN routing

By default a connected client reaches only the home server. Reaching the rest of the LAN (packet
forwarding + NAT) is an opt-in nftables implementation behind `lanAccess`. Disable it and the module
still exposes the derived `peers` list (`{ name, device, ip, fullAccess }`), so you can build your
own forwarding and firewall rules from it.
