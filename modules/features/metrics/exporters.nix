# Exporters for Prometheus, on the overlay only: the system with its services and timers, the
# disks' SMART health, and Postgres where the host keeps axon.databases.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, ... }:
    let
      inherit (config.axon)
        databases
        disk
        host
        spacePath
        spaces
        ;
      inherit (config.axon.registry.metrics) metrics;
      dir = "/run/prometheus-node-exporter-text";
      exporters = config.services.prometheus.exporters;

      # one mountpoint per data disk, its first space's; the other spaces are further mounts of the
      # same filesystem, or bind mounts from the boot disk
      firsts = lib.mapAttrsToList (_: fs: spacePath (lib.head (lib.attrNames fs.spaces))) (
        lib.filterAttrs (label: fs: label != "boot" && fs.spaces != { }) disk
      );
      repeated = lib.subtractLists firsts (
        lib.mapAttrsToList (_: space: space.path) (
          lib.filterAttrs (_: space: space.disk != null || space.fallback) spaces
        )
      );
      nested = map (path: "${lib.escapeRegex path}/.+") firsts;
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
