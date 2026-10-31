# Test-only stand-ins for nixpkgs breakage the framework does not own; consumers carry the same fixes as
# overlays. Drop each once nixpkgs catches up.
_final: prev: {
  # posthog is marked broken with mcp >= 2, though mcp is only its test input.
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (_pyFinal: pyPrev: {
      posthog = pyPrev.posthog.overridePythonAttrs (old: {
        doCheck = false;
        meta = old.meta // {
          broken = false;
        };
      });
    })
  ];

  # open-webui 0.12 imports `streamablehttp_client`, which mcp 2 removed.
  open-webui = prev.open-webui.overridePythonAttrs (old: {
    dependencies = map (p: if (p.pname or "") == "mcp" then prev.python3Packages.mcp_1 else p) old.dependencies;
  });

  # romm 5.4 lacks deps it imports, and its wrappers still run the rq-scheduler daemon upstream dropped
  # for `rq cron` and a worker without the `scans` queue or --with-scheduler.
  romm = prev.romm.overrideAttrs (
    finalAttrs: prevAttrs: {
      passthru = prevAttrs.passthru // {
        pythonEnv = prevAttrs.passthru.pythonEnv.override (old: {
          extraLibs =
            old.extraLibs
            ++ (with old.python.pkgs; [
              apprise
              croniter
              httpx2
            ]);
        });
      };

      postInstall =
        let
          inherit (finalAttrs.passthru) pythonEnv;
          backend = "$out/share/romm/backend";
          path = prev.lib.makeBinPath [ prev.p7zip ];
        in
        (prevAttrs.postInstall or "")
        + ''
          rm $out/bin/romm-scheduler $out/bin/romm-worker

          makeWrapper ${pythonEnv}/bin/rq $out/bin/romm-scheduler \
            --chdir ${backend} \
            --set PYTHONPATH ${backend} \
            --prefix PATH : ${path} \
            --add-flags "cron --path ${backend} --connection-class handler.redis_handler.RomMRedis tasks.cron_config"

          makeWrapper ${pythonEnv}/bin/rq $out/bin/romm-worker \
            --chdir ${backend} \
            --set PYTHONPATH ${backend} \
            --prefix PATH : ${path} \
            --add-flags "worker --path ${backend} --worker-class handler.rq_worker.RomMWorker --connection-class handler.redis_handler.RomMRedis --with-scheduler high default low scans"
        '';
    }
  );
}
