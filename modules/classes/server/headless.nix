# The server class: unattended, reachable, and quiet about it.
{ lib, ... }:
{
  flake.modules.nixos.server =
    { config, ... }:
    let
      inherit (config.axon) host routed routes;
    in
    {
      documentation.enable = false;
      boot.loader.timeout = 1;

      services.smartd.enable = true;

      # a hung machine reboots by itself after 30 s
      systemd.settings.Manager.RuntimeWatchdogSec = "30s";

      assertions = [
        {
          # a server nobody can reach is a server you have to walk to
          assertion = config.users.users.root.openssh.authorizedKeys.keys != [ ];
          message = "cluster.toml: no member of [ssh] may log in to ${host.name}, and a server needs one";
        }
      ];

      warnings =
        lib.optional (!routed && routes != { })
          "hosts/${host.name}/host.toml: ${lib.concatStringsSep ", " (lib.attrNames routes)} have routes but this host runs no gateway, so other machines can't reach them; list the gateway feature here or use ssh -L";
    };
}
