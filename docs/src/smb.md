# SMB storage

`storage.smb.mounts` declares CIFS shares from the home NAS, each backed by a dedicated access group. A
service requests the shares it needs with `storage.smb = [ "media" … ]` and the framework wires the mount
dependency onto the right systemd unit — auto-resolved from the service or its OCI-container name, or named
explicitly with `storage.systemdServices`.

## Mounting strategy

The mount mode is chosen per share by whether anything depends on it:

- **Dependent mounts** mount at boot with `nofail` and rely on service retry. `RequiresMountsFor` (used to
  order services after the mount) can't coexist with lazy automount, which would force the mount at service
  start and hit the boot-time network race.
- **Independent mounts** use `x-systemd.automount` — lazy on first access — avoiding boot races entirely,
  which matters where routing isn't ready at `network-online.target`.
