# Resource control

`resourceControl.slices` defines named systemd slices with aggregate CPU/memory limits. A service places its
units in a slice with `resourceControl.slice`; non-registry units join through the slice's
`extraSystemdServices`. Empty slices are skipped, so limits apply only where something opts in.
