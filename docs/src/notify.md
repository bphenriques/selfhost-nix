# Notifications

One notification seam carries backup results, task failures, and service alerts. Producers call
`send-notification` (reading `NOTIFY_URL` and a per-publisher token); swap `notify.package` to retarget
all of them at once. Producers that already speak their own protocol (Alertmanager, *arr connectors)
stay native and are pointed at the endpoint directly.

## Topics & publishers

Messages are organised into topics (`notify.topics`). A topic is private by default (publishing needs a
token), or `public` for token-less posts. Each service or task that opts in (`integrations.notify.enable`)
becomes a publisher with its own access-scoped token, generated at boot and never stored in the Nix store.
