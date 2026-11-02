# Exporters for the cluster's Prometheus (the monitoring feature): the system (node) and the
# disks' SMART health. They run once a host in the cluster lists that feature and answer on the
# tailnet only.
{ lib, ... }:
let
  inherit (lib)
    attrValues
    concatMap
    concatStringsSep
    elem
    escapeRegex
    filterAttrs
    mkIf
    tail
    ;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) cluster disk;
      exporters = config.services.prometheus.exporters;
      monitored = filterAttrs (_: data: elem "monitoring" data.host.features) cluster.hosts != { };

      # one mountpoint per filesystem: /home, /nix and /persist are subvolumes of the boot disk,
      # and a data disk's further mounts are the same filesystem as its first; impermanence's
      # bind mounts of persisted folders aren't filesystems at all
      dataDisks = attrValues (filterAttrs (label: fs: label != "boot" && fs.mounts or { } != { }) disk);
      repeated = concatMap (fs: tail (attrValues fs.mounts)) dataDisks;
      excluded = concatStringsSep "|" (
        [ "/(dev|proc|run|sys|etc|root|var|nix|home|persist)" ] ++ map escapeRegex repeated
      );
    in
    mkIf monitored {
      services.prometheus.exporters = {
        node = {
          enable = true;
          extraFlags = [ "--collector.filesystem.mount-points-exclude=^(${excluded})($|/)" ];
        };
        smartctl.enable = true;
      };

      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
        exporters.node.port
        exporters.smartctl.port
      ];
    };
}
