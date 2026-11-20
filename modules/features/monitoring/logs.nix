# Loki: the journal of every host listing metrics (metrics/logs.nix), kept 30 days in its own
# space and not backed up, as logs are only for finding faults. Other hosts push over the
# overlay, without a login; Grafana reads it. Its ruler sends alerts on log lines to Alertmanager.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      port = 3100;
      data = config.axon.spaces.loki.path;

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
          compactor = {
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
          limits_config.retention_period = "30d";
          ruler.alertmanager_url = "http://127.0.0.1:${toString config.services.prometheus.alertmanager.port}";
          analytics.reporting_enabled = false;
        };
      };

      axon.spaces.loki = {
        inherit (config.services.loki) user group;
        units = [ "loki" ];
      };

      axon.overlay.tcpPorts = [ port ];
    };
}
