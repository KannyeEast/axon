# Prometheus: scrapes the exporters on every host in the cluster (core/metrics.nix) every 30 s
# and keeps 90 days. Its own UI at prometheus.<domain>, behind the gateway login.
# The blackbox exporter checks every route twice: "service" asks the service directly (any
# answer below 500 means it runs), "route" calls https://<name>.<domain> the way clients do
# (DNS, Caddy, certificate, the tunnel for public ones; guarded ones answer with the login).
{ lib, ... }:
let
  inherit (lib)
    attrNames
    filterAttrs
    mapAttrsToList
    range
    ;
in
{
  flake.modules.nixos.monitoring =
    { config, ... }:
    let
      inherit (config.axon) cluster services;
      exporters = config.services.prometheus.exporters;
      port = 9090;
      routed = filterAttrs (_: service: service.route != null) services;

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

      probe = module: url: {
        job_name = module;
        metrics_path = "/probe";
        params.module = [ module ];
        static_configs = mapAttrsToList (name: service: {
          targets = [ (url service.route) ];
          labels.service = name;
        }) routed;
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:${toString exporters.blackbox.port}";
          }
        ];
      };

      blackbox = builtins.toFile "blackbox.json" (
        builtins.toJSON {
          modules = {
            service = {
              prober = "http";
              timeout = "5s";
              http = {
                follow_redirects = false;
                valid_status_codes = range 200 499;
                preferred_ip_protocol = "ip4";
              };
            };
            route = {
              prober = "http";
              timeout = "10s";
              http.preferred_ip_protocol = "ip4";
            };
          };
        }
      );
    in
    {
      services.prometheus.exporters.blackbox = {
        enable = true;
        listenAddress = "127.0.0.1";
        configFile = blackbox;
      };

      services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
        inherit port;
        retentionTime = "90d";
        globalConfig.scrape_interval = "30s";
        scrapeConfigs = [
          (job "node" exporters.node.port)
          (job "smartctl" exporters.smartctl.port)
          (probe "service" (route: "http://${route.address}:${toString route.port}"))
          (probe "route" (route: "https://${route.subdomain}.${cluster.domain}"))
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
