# Radicale: the htpasswd derives from selfhost.users and enabled service accounts, the rights keep each person to their
# own collections and a service account to the items of its grants, and every change is a commit.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-radicale";

  nodes.machine =
    { config, ... }:
    {
      imports = [ common ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.git
      ];

      selfhost = {
        apps.radicale.enable = true;

        users.admin.services.radicale = {
          enable = true; # the base admin opts in
          access.serviceAccounts = [ "agent" ];
        };
        users.carol = {
          email = "carol@test.local";
          firstName = "Carol";
          lastName = "Other";
          groups = [ config.selfhost.groups.users ];
          auth.oidc.enable = false;
          services.radicale.enable = true;
        };
        users.guest = {
          email = "guest@test.local";
          firstName = "Gus";
          lastName = "Guest";
          groups = [ config.selfhost.groups.users ];
          auth.oidc.enable = false;
          # no services.radicale.enable → must be absent from the htpasswd
        };

        serviceAccounts.agent.services.radicale = {
          enable = true;
          passwordFile = "${pkgs.writeText "agent-password" "agentpw"}";
        };
      };
    };

  testScript =
    { nodes, ... }:
    let
      port = toString nodes.machine.selfhost.services.radicale.port;
      collections = nodes.machine.services.radicale.settings.storage.filesystem_folder;
      secrets = nodes.machine.selfhost.runtimeSecretsDir;
    in
    ''
      machine.wait_for_unit("radicale-configure.service")
      machine.wait_for_unit("radicale.service")
      machine.wait_for_open_port(${port})

      # Only opted-in people and enabled service accounts are provisioned.
      machine.succeed("grep -q '^admin:' /var/lib/radicale/users")
      machine.succeed("grep -q '^agent:' /var/lib/radicale/users")
      machine.fail("grep -q '^guest:' /var/lib/radicale/users")

      # The configure completed on the first try (RemainAfterExit oneshot, ordered before radicale) — no
      # crash-restart loop while deriving the htpasswd.
      machine.succeed("test \"$(systemctl show radicale-configure.service -p NRestarts --value)\" = 0")

      machine.succeed("printf agentpw > /tmp/agent")
      for user in ["admin", "carol"]:
          machine.succeed(f"cp ${secrets}/radicale-password-{user} /tmp/{user}")

      def expect(user, method, path, codes, body="", xml=False):
          machine.succeed(f"printf '%b' '{body}' > /tmp/body")
          got = machine.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}' -u \"{user}:$(cat /tmp/{user})\" -X {method} -H 'Depth: 1' "
              f"-H 'Content-Type: {'application/xml' if xml else 'text/calendar'}' --data-binary @/tmp/body "
              f"http://127.0.0.1:${port}/{path}"
          ).strip()
          assert got in codes, f"{user} {method} {path}: {got}, expected {codes}"

      def event(uid):
          return f"BEGIN:VCALENDAR\\r\\nVERSION:2.0\\r\\nPRODID:test\\r\\nBEGIN:VEVENT\\r\\nUID:{uid}\\r\\nDTSTAMP:20260101T000000Z\\r\\nDTSTART:20260102T100000Z\\r\\nSUMMARY:{uid}\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"

      calendar = "<?xml version=\"1.0\"?><mkcol xmlns=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><set><prop><resourcetype><collection/><C:calendar/></resourcetype></prop></set></mkcol>"
      rename = "<?xml version=\"1.0\"?><propertyupdate xmlns=\"DAV:\"><set><prop><displayname>x</displayname></prop></set></propertyupdate>"

      for user in ["admin", "carol"]:
          expect(user, "PROPFIND", f"{user}/", ["207"])
          expect(user, "MKCOL", f"{user}/cal/", ["201"], calendar, xml=True)
      expect("admin", "PUT", "admin/cal/a.ics", ["201"], event("a"))

      # People keep to their own collections.
      expect("carol", "PROPFIND", "admin/cal/", ["403"])
      expect("admin", "PROPFIND", "carol/cal/", ["403"])

      # The agent changes the items its grant covers, and nothing else.
      expect("agent", "PROPFIND", "admin/", ["207"])
      expect("agent", "PUT", "admin/cal/b.ics", ["201"], event("b"))
      expect("agent", "DELETE", "admin/cal/a.ics", ["200", "204"])
      expect("agent", "DELETE", "admin/cal/", ["403"])
      expect("agent", "PUT", "admin/cal/", ["403"], "BEGIN:VCALENDAR\\r\\nVERSION:2.0\\r\\nEND:VCALENDAR\\r\\n")
      expect("agent", "PROPPATCH", "admin/cal/", ["403"], rename, xml=True)
      expect("agent", "MKCOL", "admin/new/", ["201"], calendar, xml=True)  # adding is not destructive, and rights cannot deny it
      expect("agent", "PROPFIND", "carol/", ["403"])
      expect("agent", "PROPFIND", "agent/", ["207"])
      expect("agent", "MKCOL", "agent/cal/", ["403"], calendar, xml=True)

      # Every change is a commit naming its login, so the item the agent deleted can be restored.
      git = "runuser -u radicale -- git -C ${collections}"
      machine.succeed(f"{git} log --format=%s -- collection-root/admin/cal/a.ics | grep -q 'Changes by agent'")
      machine.succeed(f"{git} log --format=%s | grep -q 'Changes by carol'")
      machine.succeed(f"test -z \"$({git} status --porcelain)\"")
      machine.succeed(f"{git} checkout -q HEAD~2 -- collection-root/admin/cal/a.ics && {git} -c user.name=admin -c user.email=admin@localhost commit -q -m Restore")
      expect("admin", "GET", "admin/cal/a.ics", ["200"])
    '';
}
