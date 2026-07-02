# Dashboard

Services and `external` entries that opt into `integrations.homepage` (on by default for anything with a
route) generate dashboard tiles, grouped by their `group`. There are two ways to render them:

- **Bundled** (`apps.homepage.enable`), a managed homepage-dashboard, out of the box. It only wires the
  tiles and route — set theme, layout, widgets, and branding on `services.homepage-dashboard` yourself.
- **Data tier**: leave it off and read the read-only `dashboards.generatedTiles` into a homepage you own,
  deciding tabs, layout, and visuals yourself.

The framework supplies the data; visual presentation belongs to the consumer.
