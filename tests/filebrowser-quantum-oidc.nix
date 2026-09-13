# The OIDC branch of the filebrowser-quantum adapter, eval-only on purpose: Quantum validates the
# issuer at start-up and exits fatally when it cannot be reached, so booting this branch would need a
# real HTTPS provider rather than a declared one. What matters here is the wiring the VM cannot show.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;

  cfg = evalConfig {
    selfhost = {
      mail = {
        host = "smtp.test.local";
        from = "admin@test.local";
        user = "admin@test.local";
        passwordFile = builtins.toFile "smtp-pw" "dummy";
      };
      auth.oidc.pocket-id.enable = true;
      apps.filebrowser-quantum.enable = true;
      users.admin.services.filebrowser-quantum.enable = true;
    };
  };

  entry = cfg.selfhost.services.filebrowser-quantum;
  fb = cfg.services.filebrowser-quantum;
  oidc = fb.settings.auth.methods.oidc;
  env = cfg.selfhost.runtimeTemplates."filebrowser-quantum.env".content;
  check = msg: cond: lib.assertMsg cond "filebrowser-quantum oidc: ${msg}";
in
# With a provider active the app federates instead of leaning on the gateway, which is what stops it
# trusting a header nobody is set to strip under this model.
assert check "federates when a provider is active" (entry.access.model == "oidc");
assert check "does not trust the proxy header" (!fb.settings.auth.methods.proxy.enabled);
assert check "reconciles oidc accounts" (fb.loginMethod == "oidc");
assert check "oidc method is enabled" oidc.enabled;
assert check "registers the callback Quantum actually serves" (
  entry.access.oidc.callbackURLs == [ "${entry.publicUrl}/api/auth/oidc/callback" ]
);
assert check "points at the active provider" (oidc.issuerUrl == cfg.selfhost.auth.oidc.provider.issuerUrl);
# Without this the declared groups are decorative: under `oidc` the framework leaves enforcement to
# the service, so a valid token from outside them would otherwise be admitted.
assert check "enforces the declared groups in-app" (oidc.userGroups == entry.access.allowedGroups);
assert check "defaults the groups to admin" (entry.access.allowedGroups == [ cfg.selfhost.groups.admin ]);
# Credentials reach the service through the rendered env file, never the store.
assert check "renders the client id" (lib.hasInfix "FILEBROWSER_OIDC_CLIENT_ID" env);
assert check "renders the client secret" (lib.hasInfix "FILEBROWSER_OIDC_CLIENT_SECRET" env);
assert check "keeps secrets out of the config" (!(lib.hasInfix "clientSecret" (builtins.toJSON fb.settings)));
pkgs.runCommand "selfhost-filebrowser-quantum-oidc-eval" { } "touch $out"
