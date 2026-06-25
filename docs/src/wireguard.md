# WireGuard VPN

An opt-in WireGuard server with a per-user device registry and in-person client provisioning. Like
`storage.smb`, it is gated; importing the module changes nothing until `selfhost.vpn.wireguard.enable`.

## Provisioning model

The server holds the authority: it generates each client's keypair (clients never submit their own).
To onboard a device, run `wg-manage show <name>`, which renders a QR code to scan directly onto the
device in person; there is no email or other out-of-band key exchange. Devices are declared under
`users.<name>.services.wireguard.devices`.

## LAN routing

By default a connected client reaches only the home server. Reaching the rest of the LAN (packet
forwarding + NAT) is an opt-in nftables implementation behind `lanAccess`. Disable it and the module
still exposes the derived `peers` list (`{ name, device, ip, fullAccess }`), so you can build your
own forwarding and firewall rules from it.

## Dynamic DNS

On a residential connection the public IP is usually not static, so clients can't dial a fixed
`endpoint`. The general `selfhost.ddns.desec` module keeps a hostname pointed at the current IP — set
`endpoint` to that name and let clients resolve it:

```nix
selfhost.ddns.desec = {
  enable = true;
  tokenFile = config.sops.secrets."desec/token".path;
  domains = [ config.selfhost.vpn.wireguard.endpoint ];
};
```

It refreshes on a timer plus once at boot (which catches the common case where the IP changes on a
reconnect). The WireGuard mobile app re-resolves the hostname when a handshake fails, so a client
recovers on its own once the record updates.

Publishing your home IP in DNS is low-risk here: WireGuard is silent — it never answers an
unauthenticated packet — so the endpoint is invisible to scanners and offers nothing to hit. That
property only covers the WireGuard port itself; don't reuse this to expose other services directly,
since that means opening ports.
