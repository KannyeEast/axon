# Exporters for the cluster's Prometheus (the monitoring feature): the system (node), with the state
# of every system service, and the disks' SMART health. They answer on the overlay only. The node
# exporter also serves the textfiles other parts of this feature leave in
# /run/prometheus-node-exporter-text.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, ... }:
    let
      inherit (config.axon) disk;
      dir = "/run/prometheus-node-exporter-text";
      exporters = config.services.prometheus.exporters;

      # one mountpoint per filesystem: /home, /nix and /persist are subvolumes of the boot disk,
      # and a data disk's further mounts are the same filesystem as its first; impermanence's
      # bind mounts of persisted folders aren't filesystems at all
      dataDisks = lib.attrValues (
        lib.filterAttrs (label: fs: label != "boot" && fs.mounts or { } != { }) disk
      );
      repeated = lib.concatMap (fs: lib.tail (lib.attrValues fs.mounts)) dataDisks;
      excluded = lib.concatStringsSep "|" (
        [ "/(dev|proc|run|sys|etc|root|var|nix|home|persist)" ] ++ map lib.escapeRegex repeated
      );
    in
    {
      services.prometheus.exporters = {
        node = {
          enable = true;
          # failed services for the UnitFailed alert; other unit types only add series
          enabledCollectors = [ "systemd" ];
          extraFlags = [
            "--collector.filesystem.mount-points-exclude=^(${excluded})($|/)"
            "--collector.textfile.directory=${dir}"
            "--collector.systemd.unit-include=.+[.]service"
          ];
        };
        smartctl.enable = true;
      };
      systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];

      axon.overlay.tcpPorts = [
        exporters.node.port
        exporters.smartctl.port
      ];
    };
}
