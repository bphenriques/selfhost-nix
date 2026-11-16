# Test-only stand-ins for nixpkgs breakage the framework does not own; consumers carry the same fixes as
# overlays. Drop each once nixpkgs catches up.
_final: prev: {
  # romm 5.4's wrappers still run the rq-scheduler daemon upstream dropped for `rq cron`, and a worker
  # without the `scans` queue or --with-scheduler.
  romm = prev.romm.overrideAttrs (
    finalAttrs: prevAttrs: {
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
