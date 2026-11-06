# Grafana at grafana.<domain>: graphs over Prometheus, with its data source and dashboards
# provisioned from here. Behind the gateway login, which Grafana trusts: the user the login names
# is signed in, and the host.toml user is Grafana's admin, with monitoring/password for the API.
# Without a gateway on this host it stays on localhost, with only its own login.
# Its secret key is made on first start and kept in its persisted state folder.
# The "Start page" dashboard is written here; its panels are the System graphs on the gateway's
# start page, each embedded on its own.
{ lib, ... }:
let
  inherit (lib)
    genAttrs
    imap1
    listToAttrs
    nameValuePair
    ;
in
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      inherit (config.axon) routed services user;
      port = 3001;
      state = "/var/lib/grafana";
      address = if routed then services.grafana.route.host else "127.0.0.1";
      url = if routed then services.grafana.route.url else "http://${services.grafana.route.endpoint}";

      percent = {
        unit = "percent";
        min = 0;
        max = 100;
      };
      timeseries = title: unit: targets: {
        type = "timeseries";
        inherit title targets;
        fieldConfig.defaults = unit // {
          custom = {
            fillOpacity = 10;
            showPoints = "never";
          };
        };
        options.tooltip.mode = "multi";
      };
      query = expr: legendFormat: { inherit expr legendFormat; };
      column = name: properties: {
        matcher = {
          id = "byName";
          options = name;
        };
        inherit properties;
      };
      property = id: value: { inherit id value; };

      # tunnels and bridges carry the same traffic a second time
      physical = ''device=~"en.*|eth.*|wl.*"'';

      # in tile order, two per row
      panels = [
        (timeseries "CPU" percent [
          (query ''100 * (1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])))'' "{{host}}")
        ])
        (timeseries "Memory" percent [
          (query "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)" "{{host}}")
        ])
        (timeseries "Network" { unit = "Bps"; } [
          (query "sum by (host) (rate(node_network_receive_bytes_total{${physical}}[5m]))" "{{host}} in")
          (query "sum by (host) (rate(node_network_transmit_bytes_total{${physical}}[5m]))" "{{host}} out")
        ])
        (timeseries "Temperature" { unit = "celsius"; } [
          (query "max by (host) (node_hwmon_temp_celsius)" "{{host}}")
        ])
        {
          type = "table";
          title = "Disks";
          targets =
            imap1
              (i: expr: {
                inherit expr;
                refId = lib.elemAt [ "A" "B" "C" ] (i - 1);
                format = "table";
                instant = true;
              })
              [
                ''node_filesystem_size_bytes{fstype!="tmpfs"}''
                ''node_filesystem_size_bytes{fstype!="tmpfs"} - node_filesystem_avail_bytes{fstype!="tmpfs"}''
                ''100 * (1 - node_filesystem_avail_bytes{fstype!="tmpfs"} / node_filesystem_size_bytes{fstype!="tmpfs"})''
              ];
          # one row per filesystem with its three values side by side
          transformations = [
            {
              id = "merge";
              options = { };
            }
            {
              id = "organize";
              options = {
                excludeByName = genAttrs [
                  "Time"
                  "class"
                  "device"
                  "fstype"
                  "instance"
                  "job"
                ] (_: true);
                indexByName = {
                  host = 0;
                  mountpoint = 1;
                  "Value #A" = 2;
                  "Value #B" = 3;
                  "Value #C" = 4;
                };
                renameByName = {
                  host = "Host";
                  mountpoint = "Filesystem";
                  "Value #A" = "Size";
                  "Value #B" = "Used";
                  "Value #C" = "Use";
                };
              };
            }
          ];
          fieldConfig = {
            defaults = { };
            overrides = [
              (column "Size" [ (property "unit" "decbytes") ])
              (column "Used" [ (property "unit" "decbytes") ])
              (column "Use" [
                (property "unit" "percent")
                (property "min" 0)
                (property "max" 100)
                (property "custom.cellOptions" {
                  type = "gauge";
                  mode = "basic";
                })
                (property "thresholds" {
                  mode = "absolute";
                  steps = [
                    {
                      color = "green";
                      value = null;
                    }
                    {
                      color = "orange";
                      value = 70;
                    }
                    {
                      color = "red";
                      value = 85;
                    }
                  ];
                })
              ])
            ];
          };
          options = {
            cellHeight = "sm";
            sortBy = [
              {
                displayName = "Filesystem";
                desc = false;
              }
              {
                displayName = "Host";
                desc = false;
              }
            ];
          };
        }
        (timeseries "Disk I/O" { unit = "Bps"; } [
          (query ''sum by (host) (rate(node_disk_read_bytes_total{device!~"loop.*|zram.*|dm-.*"}[5m]))'' "{{host}} read")
          (query ''sum by (host) (rate(node_disk_written_bytes_total{device!~"loop.*|zram.*|dm-.*"}[5m]))'' "{{host}} write")
        ])
      ];

      start = lib.toJSON {
        uid = "start";
        title = "Start page";
        time = {
          from = "now-24h";
          to = "now";
        };
        refresh = "1m";
        panels = imap1 (
          id: panel:
          panel
          // {
            inherit id;
            datasource.uid = "prometheus";
            gridPos = {
              w = 12;
              h = 8;
              x = if lib.mod id 2 == 1 then 0 else 12;
              y = 8 * ((id - 1) / 2);
            };
          }
        ) panels;
      };

      dashboards = pkgs.linkFarm "grafana-dashboards" [
        {
          name = "start.json";
          path = pkgs.writeText "start.json" start;
        }
        {
          name = "node-exporter-full.json";
          path = pkgs.fetchurl {
            name = "node-exporter-full.json";
            url = "https://grafana.com/api/dashboards/1860/revisions/45/download";
            sha256 = "11hrll7fm626ikbva5md4gm0rca537vp4xsxa9sxl1pk15s6nk0q";
          };
        }
        {
          name = "blackbox-http.json";
          # written for import, which asks for the data source; provisioning doesn't
          path = pkgs.runCommand "blackbox-http.json" { } ''
            sed 's/''${DS_PROMETHEUS}/Prometheus/g' ${
              pkgs.fetchurl {
                name = "blackbox-http.json";
                url = "https://grafana.com/api/dashboards/13659/revisions/1/download";
                sha256 = "0m4gskf936jam2mrwhd8i1mnam9y26wklcg69hmaba60a1c4aw4y";
              }
            } >$out
          '';
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
            domain = address;
            root_url = "${url}/";
          };
          security = {
            # the start page shows panels of the Start page dashboard in frames
            allow_embedding = true;
            admin_user = user.name;
            admin_password = "$__file{${config.sops.secrets."monitoring/password".path}}";
            secret_key = "$__file{${state}/secret_key}";
          };
          # Caddy, on this host, passes the gateway login's user
          "auth.proxy" = {
            enabled = routed;
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
          icon = "grafana.svg";
          instances = listToAttrs (
            imap1 (
              id: panel:
              nameValuePair panel.title {
                description = "last 24 hours";
                link = "${url}/d/start";
                widget = {
                  type = "iframe";
                  name = "grafana-${toString id}";
                  src = "${url}/d-solo/start/start?panelId=${toString id}&theme=dark&from=now-24h&to=now&refresh=1m";
                  classes = "h-60 sm:h-60 md:h-60 lg:h-60 xl:h-60 2xl:h-72";
                  allowScrolling = "no";
                };
              }
            ) panels
          );
        };
        backup.paths = [ state ];
      };
    };
}
