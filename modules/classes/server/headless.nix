# The server class: unattended, reachable, and quiet about it.
{ lib, ... }:
{
  flake.modules.nixos.server =
    { config, ... }:
    let
      inherit (config.axon)
        host
        hostsWith
        routed
        routes
        ;
      gateways = lib.attrNames (hostsWith "gateway");
      names = lib.concatStringsSep ", " (lib.attrNames routes);
    in
    {
      documentation.enable = false;
      boot.loader.timeout = 1;

      services.smartd = {
        enable = true;
        # a failing disk alerts through Prometheus (DiskUnhealthy), not on every open terminal
        notifications.wall.enable = false;
      };

      systemd.settings.Manager.RuntimeWatchdogSec = "30s";

      assertions = [
        {
          # a server nobody can reach is a server you have to walk to
          assertion = config.users.users.root.openssh.authorizedKeys.keys != [ ];
          message = "cluster.toml: no member of [ssh] may log in to ${host.name}, and a server needs one";
        }
      ];

      warnings = lib.optional (!routed && routes != { }) (
        if gateways == [ ] then
          "hosts/${host.name}/host.toml: ${names} have routes but this host runs no gateway, so other machines can't reach them; list the gateway feature here or use ssh -L"
        else
          "hosts/${host.name}/host.toml: ${names} have routes, but the gateway on ${lib.concatStringsSep ", " gateways} routes only its own host's services, and their logins stay local; reach them through ssh -L, or move them to that host"
      );
    };
}
