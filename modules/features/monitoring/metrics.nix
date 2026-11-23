# Prometheus: the exporters of every host listing metrics and a probe of every route, kept 90 days.
# No route of its own: Grafana and the start page read it over the overlay, without a login.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        host
        hostsWith
        registry
        routed
        routes
        ;
      exporters = config.services.prometheus.exporters;
      scraped = hostsWith "metrics";
      # files and forge keep their databases (axon.databases) on servers, so Postgres runs there
      databases = lib.filterAttrs (
        _: data:
        data.host.class == "server" && lib.intersectLists [ "files" "forge" ] data.host.features != [ ]
      ) scraped;

      # the volumes a host's data disks mount, as its axon.volumes
      mounted = data: lib.concatMapAttrs (_: fs: fs.mounts or { }) (removeAttrs data.disk [ "boot" ]);
      # the exporters a host runs: its features' metrics, where it mounts their volume
      runs =
        data:
        lib.filterAttrs (_: spec: spec.volume == null || mounted data ? ${spec.volume}) (
          lib.mergeAttrsList (map (feature: registry.${feature}.metrics) data.host.features)
        );
      # one job per name, a target per host that runs it
      jobs =
        lib.zipAttrsWith
          (
            name: targets:
            job name (lib.head targets).port (lib.mergeAttrsList (map (target: target.hosts) targets))
          )
          (
            lib.mapAttrsToList (
              name: data:
              lib.mapAttrs (_: spec: {
                inherit (spec) port;
                hosts.${name} = data;
              }) (runs data)
            ) scraped
          );

      # class: alerts that a machine is off only make sense for servers
      job = name: exporterPort: hosts: {
        job_name = name;
        static_configs = lib.mapAttrsToList (name: data: {
          targets = [ "${name}:${toString exporterPort}" ];
          labels = {
            host = name;
            class = data.host.class;
          };
        }) hosts;
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
                # a service with its own TLS has a certificate for its route, not for 127.0.0.1
                tls_config.insecure_skip_verify = true;
              };
            };
            # a redirect counts: gated routes answer with the login's
            route = {
              prober = "http";
              http = {
                follow_redirects = false;
                valid_status_codes = lib.range 200 399;
                preferred_ip_protocol = "ip4";
              };
            };
          };
        }
      );
    in
    {
      # ── service ────────
      services.prometheus = {
        enable = true;
        retentionTime = "90d";
        globalConfig.scrape_interval = "30s";
        scrapeConfigs =
          lib.attrValues jobs
          ++ [ (probe "service" (route: route.internal + route.health) routes) ]
          ++ lib.optional routed (probe "route" (route: route.url + route.health) routes)
          ++ lib.optional (databases != { }) (job "postgres" exporters.postgres.port databases);
      };

      services.prometheus.exporters.blackbox = {
        enable = true;
        listenAddress = "127.0.0.1";
        configFile = blackbox;
        # at info it logs every redirect a probe meets
        extraFlags = [ "--log.prober=warn" ];
      };

      # ── data ────────
      axon.persist.state.directories = [
        {
          directory = "/var/lib/prometheus2";
          user = "prometheus";
          group = "prometheus";
          mode = "0700";
        }
      ];

      # ── contracts ────────
      axon.overlay.tcpPorts = [ config.services.prometheus.port ];
    };
}
