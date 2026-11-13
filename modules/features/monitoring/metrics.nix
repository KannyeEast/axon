# Prometheus: scrapes the exporters on every host listing the metrics feature and keeps 90 days.
# Grafana reads it; it has no route of its own. The blackbox exporter checks every route:
# "service" asks the service directly (any answer below 500 means it runs). Where this host runs
# the gateway, https://<name>.<domain> is also called the way clients do (DNS, Caddy, certificate,
# the tunnel for public ones): "route" (own login) must answer, "guarded" (behind the gateway
# login) must refuse with 401.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        cluster
        host
        routed
        routes
        ;
      exporters = config.services.prometheus.exporters;
      scraped = lib.filterAttrs (_: data: lib.elem "metrics" data.host.features) cluster.hosts;
      open = lib.filterAttrs (_: service: service.route.access == "open") routes;
      guarded = lib.filterAttrs (_: service: service.route.access != "open") routes;
      external = route: route.url;

      # every series carries the host it's about, and its class: alerts that a machine is off
      # only make sense for servers
      job = name: exporterPort: {
        job_name = name;
        static_configs = lib.mapAttrsToList (name: data: {
          targets = [ "${name}:${toString exporterPort}" ];
          labels = {
            host = name;
            class = data.host.class;
          };
        }) scraped;
        # "node1" instead of "node1:9100" in graphs and alerts
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            regex = "([^:]+):.*";
            target_label = "instance";
          }
        ];
      };

      probe = module: url: targets: {
        job_name = module;
        metrics_path = "/probe";
        params.module = [ module ];
        static_configs = lib.mapAttrsToList (name: service: {
          targets = [ (url service.route) ];
          labels = {
            host = host.name;
            service = name;
          };
        }) targets;
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

      blackbox = pkgs.writeText "blackbox.json" (
        lib.toJSON {
          modules = {
            service = {
              prober = "http";
              timeout = "5s";
              http = {
                follow_redirects = false;
                valid_status_codes = lib.range 200 499;
                preferred_ip_protocol = "ip4";
              };
            };
            route = {
              prober = "http";
              http.preferred_ip_protocol = "ip4";
            };
            # the gateway login refuses requests that aren't from a browser instead of redirecting
            guarded = {
              prober = "http";
              http = {
                valid_status_codes = [ 401 ];
                preferred_ip_protocol = "ip4";
              };
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
        retentionTime = "90d";
        globalConfig.scrape_interval = "30s";
        scrapeConfigs = [
          (job "node" exporters.node.port)
          (job "smartctl" exporters.smartctl.port)
          (probe "service" (route: "http://${route.endpoint}") routes)
        ]
        ++ lib.optionals routed [
          (probe "route" external open)
          (probe "guarded" external guarded)
        ];
      };

      axon.persist.state.directories = [
        {
          directory = "/var/lib/prometheus2";
          user = "prometheus";
          group = "prometheus";
          mode = "0700";
        }
      ];
    };
}
