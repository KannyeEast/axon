# Grafana at grafana.<domain>: graphs over Prometheus, with its data source and dashboards
# provisioned from here. Behind the gateway login, which Grafana trusts: the user the login names
# is signed in, and the host.toml user is Grafana's admin, with monitoring/password for the API.
# Its secret key is made on first start and kept in its persisted state folder.
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      inherit (config.axon) cluster user;
      port = 3001;
      state = "/var/lib/grafana";
      url = "https://grafana.${cluster.domain}";

      dashboards = pkgs.linkFarm "grafana-dashboards" [
        {
          name = "node-exporter-full.json";
          path = pkgs.fetchurl {
            name = "node-exporter-full.json";
            url = "https://grafana.com/api/dashboards/1860/revisions/45/download";
            sha256 = "11hrll7fm626ikbva5md4gm0rca537vp4xsxa9sxl1pk15s6nk0q";
          };
        }
      ];
    in
    {
      services.grafana = {
        enable = true;
        dataDir = state;
        settings = {
          server = {
            http_addr = "127.0.0.1";
            http_port = port;
            domain = "grafana.${cluster.domain}";
            root_url = "${url}/";
          };
          security = {
            admin_user = user.name;
            admin_password = "$__file{${config.sops.secrets."monitoring/password".path}}";
            secret_key = "$__file{${state}/secret_key}";
          };
          # Caddy, on this host, passes the gateway login's user
          "auth.proxy" = {
            enabled = true;
            header_name = "Remote-User";
            header_property = "username";
            auto_sign_up = true;
            whitelist = "127.0.0.1";
          };
          analytics = {
            reporting_enabled = false;
            check_for_updates = false;
          };
        };
        provision = {
          enable = true;
          datasources.settings.datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              uid = "prometheus";
              url = "http://127.0.0.1:${toString config.services.prometheus.port}";
              isDefault = true;
            }
          ];
          dashboards.settings.providers = [
            {
              name = "axon";
              options.path = dashboards;
            }
          ];
        };
      };

      systemd.services.grafana.preStart = ''
        umask 077
        [ -e ${state}/secret_key ] || head -c 32 /dev/urandom | base64 -w0 >${state}/secret_key
      '';

      sops.secrets."monitoring/password".owner = "grafana";

      axon.persist.directories = [
        {
          directory = state;
          user = "grafana";
          group = "grafana";
          mode = "0700";
        }
      ];

      axon.services.grafana = {
        route.port = port;
        dashboard = {
          name = "Grafana";
          group = "System";
          description = "Graphs for every host";
          icon = "grafana.svg";
          widget = {
            type = "grafana";
            version = 2;
            username = user.name;
          };
          secrets.password = "monitoring/password";
        };
        backup.paths = [ state ];
      };
    };
}
