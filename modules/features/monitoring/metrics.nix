# Prometheus: scrapes the exporters on every host in the cluster (core/metrics.nix) every 30 s
# and keeps 90 days. Its own UI at prometheus.<domain>, behind the gateway login.
# The blackbox exporter checks every route twice: "service" asks the service directly (any
# answer below 500 means it runs), and https://<name>.<domain> is called the way clients do
# (DNS, Caddy, certificate, the tunnel for public ones): "route" for services with their own
# login must answer, "guarded" for those behind the gateway login must refuse with 401.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    filterAttrs
    length
    mapAttrs
    mapAttrsToList
    range
    ;
in
{
  flake.modules.nixos.monitoring =
    { config, ... }:
    let
      inherit (config.axon) cluster host services;
      exporters = config.services.prometheus.exporters;
      port = 9090;
      routed = filterAttrs (_: service: service.route != null) services;
      grafana = "https://grafana.${cluster.domain}";

      metric = label: query: format: { inherit label query format; };
      percent = {
        type = "percent";
        options.maximumFractionDigits = 0;
      };
      whole = suffix: {
        type = "number";
        inherit suffix;
        options.maximumFractionDigits = 0;
      };
      open = filterAttrs (_: service: service.route.access == "open") routed;
      guarded = filterAttrs (_: service: service.route.access != "open") routed;
      external = route: "https://${route.subdomain}.${cluster.domain}";

      # every series carries the host it's about, and its class: alerts that a machine is off
      # only make sense for servers
      job = name: exporterPort: {
        job_name = name;
        static_configs = mapAttrsToList (name: data: {
          targets = [ "${name}:${toString exporterPort}" ];
          labels = {
            host = name;
            class = data.host.class;
          };
        }) cluster.hosts;
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
        static_configs = mapAttrsToList (name: service: {
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
            # the gateway login refuses requests that aren't from a browser instead of redirecting
            guarded = {
              prober = "http";
              timeout = "10s";
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
        inherit port;
        retentionTime = "90d";
        globalConfig.scrape_interval = "30s";
        scrapeConfigs = [
          (job "node" exporters.node.port)
          (job "smartctl" exporters.smartctl.port)
          (probe "service" (route: "http://${route.address}:${toString route.port}") routed)
          (probe "route" external open)
          (probe "guarded" external guarded)
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

      # the System tiles on the start page: one per host and one for the cluster, each leading
      # to its Grafana dashboard
      axon.services.prometheus = {
        route.port = port;
        dashboard = {
          name = "Prometheus";
          group = "System";
          icon = "prometheus.svg";
          widget.type = "prometheusmetric";
          instances =
            mapAttrs (name: data: {
              description = data.host.class;
              icon = "mdi-server";
              link = "${grafana}/d/rYdddlPWk/node-exporter-full?var-job=node&var-nodename=${name}&var-node=${name}";
              widget.metrics = [
                (metric "CPU" ''100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle",host="${name}"}[5m])))''
                  percent
                )
                (metric "RAM"
                  ''100 * (1 - node_memory_MemAvailable_bytes{host="${name}"} / node_memory_MemTotal_bytes{host="${name}"})''
                  percent
                )
                (metric "Disk"
                  ''100 * max(1 - node_filesystem_avail_bytes{host="${name}",fstype!="tmpfs"} / node_filesystem_size_bytes{host="${name}",fstype!="tmpfs"})''
                  percent
                )
                (metric "Temp" ''max(node_hwmon_temp_celsius{host="${name}"})'' (whole " °C"))
              ];
            }) cluster.hosts
            // {
              Cluster = {
                description = "services, alerts, disks, certificates";
                link = "${grafana}/d/NEzutrbMk/blackbox-exporter-http-prober";
                widget.metrics = [
                  (metric "Services" ''sum(probe_success{job="service"})'' (
                    whole "/${toString (length (attrNames routed))}"
                  ))
                  (metric "Alerts" ''count(ALERTS{alertstate="firing"}) or vector(0)'' (whole ""))
                  (metric "SMART errors" "count(smartctl_device_smart_status != 1) or vector(0)" (whole ""))
                  (metric "Certificate" ''min(probe_ssl_earliest_cert_expiry{job=~"route|guarded"} - time()) / 86400''
                    (whole " d")
                  )
                ];
              };
            };
        };
      };
    };
}
