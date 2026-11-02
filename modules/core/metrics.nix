# Exporters for the cluster's Prometheus (the monitoring feature): the system (node) and the
# disks' SMART health. They run once a host in the cluster lists that feature and answer on the
# tailnet only.
{ lib, ... }:
let
  inherit (lib) elem filterAttrs mkIf;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) cluster;
      exporters = config.services.prometheus.exporters;
      monitored = filterAttrs (_: data: elem "monitoring" data.host.features) cluster.hosts != { };
    in
    mkIf monitored {
      services.prometheus.exporters = {
        node = {
          enable = true;
          # impermanence bind-mounts every persisted folder; only the real filesystems count
          extraFlags = [
            "--collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|etc|root|var|nix/store)($|/)"
          ];
        };
        smartctl.enable = true;
      };

      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
        exporters.node.port
        exporters.smartctl.port
      ];
    };
}
