# Backups

Each entry in `backup.targets` is an independent rustic pipeline with its own repository, encryption,
retention, and schedule. A backup run and a periodic verification run are scheduled per target; failures
notify.

## What gets snapshotted

A target assembles its tree from two sources:

- **Service hooks**: a registry service declares `backup.package`, a script that writes into `OUTPUT_DIR`
  ordered after the relevant unit; the target lists which services to include.
- **Bindings**: arbitrary paths mounted read-only into the snapshot tree.

Standalone `hooks` cover content not tied to a registry service. Each run assembles into a scratch area,
snapshots it, and cleans up, on success or failure.
