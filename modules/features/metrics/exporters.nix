# Exporters for Prometheus, on the overlay only: the system with its services and timers, the
# disks' SMART health, and Postgres where the host keeps axon.databases.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, ... }:
    let
      inherit (config.axon) databases disk host;
      inherit (config.axon.registry.metrics) metrics;
      dir = "/run/prometheus-node-exporter-text";
      exporters = config.services.prometheus.exporters;

      # one mountpoint per filesystem; the rest are subvolumes, further mounts or bind mounts
      dataDisks = lib.attrValues (
        lib.filterAttrs (label: fs: label != "boot" && fs.mounts or { } != { }) disk
      );
      repeated = lib.concatMap (fs: lib.tail (lib.attrValues fs.mounts)) dataDisks;
      nested = map (fs: "${lib.escapeRegex (lib.head (lib.attrValues fs.mounts))}/.+") dataDisks;
      excluded = lib.concatStringsSep "|" (
        [ "/(dev|proc|run|sys|etc|root|var|nix|home|persist)" ] ++ map lib.escapeRegex repeated ++ nested
      );
    in
    {
      # ── service ────────
      services.prometheus.exporters = {
        node = {
          enable = true;
          inherit (metrics.node) port;
          # services for UnitFailed, timers for the dumps' last run; other units only add series
          enabledCollectors = [ "systemd" ];
          extraFlags = [
            "--collector.filesystem.mount-points-exclude=^(${excluded})($|/)"
            "--collector.textfile.directory=${dir}"
            "--collector.systemd.unit-include=.+[.](service|timer)"
          ];
        };
        smartctl = {
          enable = true;
          inherit (metrics.smartctl) port;
          # at info it logs every disk it finds on each rescan, every few minutes
          extraFlags = [ "--log.level=warn" ];
        };
        # its default connection: the postgres role over the local socket
        postgres = lib.mkIf (databases != [ ]) {
          enable = true;
          runAsLocalSuperUser = true;
        };
      };

      # ── units ────────
      systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];

      # ── contracts ────────
      axon.overlay.tcpPorts = [
        exporters.node.port
        exporters.smartctl.port
      ]
      ++ lib.optional (databases != [ ]) exporters.postgres.port;

      # ── checks ────────
      # monitoring/metrics.nix finds Postgres only through files or forge in a feature list
      warnings =
        lib.optional
          (
            databases != [ ]
            && !(host.class == "server" && lib.intersectLists [ "files" "forge" ] host.features != [ ])
          )
          "modules/features/monitoring/metrics.nix: Postgres on ${host.name} isn't scraped; scrape it where its databases come from";
    };
}
