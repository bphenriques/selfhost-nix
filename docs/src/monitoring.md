# Monitoring

Enabling `monitoring` stands up Prometheus and, optionally, Alertmanager. Services opt in through
`integrations.monitoring` (on by default) and contribute in three ways:

- **Healthchecks** — a blackbox-exporter probe of the service's `healthcheck` URL, with default alerts
  for unreachable and slow responses.
- **Metrics** — custom `exporters` and `scrapeConfigs` merged into Prometheus.
- **Alerts** — custom `rules`.

Non-service sources (hardware, the host, Traefik) register as `scopes` and fold into the same Prometheus
config. Fired alerts route through Alertmanager to the notification seam.
