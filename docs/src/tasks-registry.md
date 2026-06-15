# Tasks

The task registry tracks externally-defined systemd units (timers, oneshots, maintenance jobs) that opt
into selfhost cross-cutting concerns. It does not create or schedule units: define those with
`systemd.services`/`systemd.timers` as usual, then list them under `tasks.<name>.systemdServices` so
notify-on-failure and storage mounts attach to them.
