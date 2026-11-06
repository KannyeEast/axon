# Exporters for the cluster's Prometheus (the monitoring feature): the system (node) and the
# disks' SMART health. They answer on the overlay only.
{ lib, ... }:
let
  inherit (lib)
    attrValues
    concatMap
    concatStringsSep
    escapeRegex
    filterAttrs
    tail
    ;
in
{
  flake.modules.nixos.metrics =
    { config, ... }:
    let
      inherit (config.axon) disk;
      exporters = config.services.prometheus.exporters;

      # one mountpoint per filesystem: /home, /nix and /persist are subvolumes of the boot disk,
      # and a data disk's further mounts are the same filesystem as its first; impermanence's
      # bind mounts of persisted folders aren't filesystems at all
      dataDisks = attrValues (filterAttrs (label: fs: label != "boot" && fs.mounts or { } != { }) disk);
      repeated = concatMap (fs: tail (attrValues fs.mounts)) dataDisks;
      excluded = concatStringsSep "|" (
        [ "/(dev|proc|run|sys|etc|root|var|nix|home|persist)" ] ++ map escapeRegex repeated
      );
    in
    {
      services.prometheus.exporters = {
        node = {
          enable = true;
          extraFlags = [ "--collector.filesystem.mount-points-exclude=^(${excluded})($|/)" ];
        };
        smartctl.enable = true;
      };

      axon.overlay.tcpPorts = [
        exporters.node.port
        exporters.smartctl.port
      ];
    };
}
