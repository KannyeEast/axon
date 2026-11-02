# Prometheus: scrapes the exporters on every host in the cluster (core/metrics.nix) every 30 s
# and keeps 90 days. Its own UI at prometheus.<domain>, behind the gateway login.
{ lib, ... }:
let
  inherit (lib) attrNames;
in
{
  flake.modules.nixos.monitoring =
    { config, ... }:
    let
      inherit (config.axon) cluster;
      exporters = config.services.prometheus.exporters;
      port = 9090;

      job = name: exporterPort: {
        job_name = name;
        static_configs = [
          { targets = map (host: "${host}:${toString exporterPort}") (attrNames cluster.hosts); }
        ];
        # "node1" instead of "node1:9100" in graphs and alerts
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            regex = "([^:]+):.*";
            target_label = "instance";
          }
        ];
      };
    in
    {
      services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
        inherit port;
        retentionTime = "90d";
        globalConfig.scrape_interval = "30s";
        scrapeConfigs = [
          (job "node" exporters.node.port)
          (job "smartctl" exporters.smartctl.port)
        ];
      };

      axon.persist.directories = [
        {
          directory = "/var/lib/prometheus2";
          user = "prometheus";
          group = "prometheus";
          mode = "0700";
        }
      ];

      axon.services.prometheus.route.port = port;
    };
}
