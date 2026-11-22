# Exporters for the cluster's Prometheus (the monitoring feature): the system (node), with the state
# of every system service and timer, the disks' SMART health and, where the host keeps
# axon.databases, Postgres. They answer on the overlay only. The node exporter also serves the
# textfiles other parts of this feature leave in /run/prometheus-node-exporter-text.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, ... }:
    let
      inherit (config.axon) databases disk host;
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
          # failed services for the UnitFailed alert, timers for when each last ran (the database
          # dumps); other unit types only add series
          enabledCollectors = [ "systemd" ];
          extraFlags = [
            "--collector.filesystem.mount-points-exclude=^(${excluded})($|/)"
            "--collector.textfile.directory=${dir}"
            "--collector.systemd.unit-include=.+[.](service|timer)"
          ];
        };
        smartctl = {
          enable = true;
          # at info it logs every disk it finds on each rescan, every few minutes
          extraFlags = [ "--log.level=warn" ];
        };
        # its default connection: the postgres role over the local socket
        postgres = lib.mkIf (databases != [ ]) {
          enable = true;
          runAsLocalSuperUser = true;
        };
      };
      systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];

      axon.overlay.tcpPorts = [
        exporters.node.port
        exporters.smartctl.port
      ]
      ++ lib.optional (databases != [ ]) exporters.postgres.port;

      # monitoring/metrics.nix scrapes Postgres where a server lists files, whose services keep the
      # databases: no other host's list says where Postgres runs
      warnings =
        lib.optional (databases != [ ] && !(host.class == "server" && lib.elem "files" host.features))
          "modules/features/monitoring/metrics.nix: Postgres on ${host.name} isn't scraped; scrape it where its databases come from";
    };
}
