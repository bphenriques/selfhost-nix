# Monitoring concern: Prometheus comes up and the auto-generated blackbox healthcheck probes a
# registered service successfully.
{
  pkgs,
  common,
  hello,
}:
pkgs.testers.runNixOSTest {
  name = "selfhost-monitoring";

  nodes.machine = {
    imports = [
      common
      hello
    ];
    selfhost.monitoring.enable = true;
  };

  testScript = ''
    machine.wait_for_unit("hello-backend.service")
    machine.wait_for_unit("prometheus.service")
    machine.wait_for_unit("prometheus-blackbox-exporter.service")
    machine.wait_until_succeeds("curl -sf localhost:9090/-/ready", timeout=60)

    # blackbox can actually probe the backend
    machine.wait_until_succeeds(
        "curl -s 'http://127.0.0.1:9116/probe?target=http://127.0.0.1:8080/&module=http_2xx' | grep -q '^probe_success 1'",
        timeout=60,
    )

    # prometheus loaded the auto-generated healthcheck scrape job
    machine.wait_until_succeeds("curl -s localhost:9090/api/v1/targets | grep -q healthcheck-http_2xx", timeout=60)
  '';
}
