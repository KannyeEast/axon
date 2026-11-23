# Loki: every host's journal, kept 30 days in its own space and not backed up, as logs are only for
# finding faults; its ruler sends alerts on log lines to Alertmanager.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      port = 3100;
      data = config.axon.spaces.loki.path;
      # on the state volume: Loki stops taking logs once the WAL's disk is 90% full
      wal = "/var/lib/loki-wal";

      # the ruler reads <dir>/<tenant>/*.yaml; without auth the tenant is "fake"
      rules = pkgs.writeTextFile {
        name = "loki-rules";
        destination = "/fake/axon.yaml";
        text = lib.toJSON {
          groups = [
            {
              name = "axon";
              rules = [
                {
                  alert = "CriticalLog";
                  expr = ''sum by (host, unit) (count_over_time({level=~"emerg|alert|crit"}[5m])) > 0'';
                  annotations.summary = "critical lines in the log{{ with $labels.unit }} of {{ . }}{{ end }}";
                }
              ];
            }
          ];
        };
      };
    in
    {
      services.loki = {
        enable = true;
        dataDir = data;
        configuration = {
          auth_enabled = false;
          server = {
            http_listen_port = port;
            # at info it logs every query and table lookup
            log_level = "warn";
            grpc_listen_address = "127.0.0.1";
          };
          common = {
            instance_addr = "127.0.0.1";
            path_prefix = data;
            replication_factor = 1;
            ring.kvstore.store = "inmemory";
            storage.filesystem = {
              chunks_directory = "${data}/chunks";
              rules_directory = "${rules}";
            };
          };
          schema_config.configs = [
            {
              from = "2026-11-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
          ingester.wal.dir = wal;
          compactor = {
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
          limits_config.retention_period = "30d";
          # the Patterns tab of Grafana's Logs Drilldown
          pattern_ingester.enabled = true;
          ruler.alertmanager_url = "http://127.0.0.1:${toString config.services.prometheus.alertmanager.port}";
          analytics.reporting_enabled = false;
        };
      };

      axon.spaces.loki = {
        inherit (config.services.loki) user group;
        units = [ "loki" ];
      };

      axon.persist.state.directories = [
        {
          directory = wal;
          inherit (config.services.loki) user group;
          mode = "0700";
        }
      ];

      axon.overlay.tcpPorts = [ port ];
    };
}
