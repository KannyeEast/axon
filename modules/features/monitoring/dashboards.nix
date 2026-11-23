# Grafana at grafana.<domain>: graphs over Prometheus, logs from Loki, the start page's tables.
# Reach: tailnet, the gateway's login.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        hostsWith
        services
        sso
        user
        ;
      inherit (services.grafana.route) name origin url;
      port = 3001;
      state = "/var/lib/grafana";
      client = sso.clients.grafana;

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
      thresholds =
        orange: red:
        property "thresholds" {
          mode = "absolute";
          steps = [
            {
              color = "green";
              value = null;
            }
            {
              color = "orange";
              value = orange;
            }
            {
              color = "red";
              value = red;
            }
          ];
        };
      level = orange: red: [
        (property "noValue" "–")
        (property "custom.cellOptions" { type = "color-text"; })
        (thresholds orange red)
      ];
      percentLevel =
        orange: red:
        [
          (property "unit" "percent")
          (property "decimals" 2)
        ]
        ++ level orange red;

      # columns are { name = expr; } in order; every query must aggregate down to the labels in keys
      table =
        title: keys: columns:
        let
          names = map (column: lib.head (lib.attrNames column)) columns;
          refs = lib.take (lib.length columns) [
            "A"
            "B"
            "C"
            "D"
          ];
          # Grafana adds " #<ref>" to the value field only when there are several queries
          field = ref: if lib.length columns == 1 then "Value" else "Value #${ref}";
        in
        {
          type = "table";
          inherit title;
          targets = lib.imap0 (i: column: {
            expr = lib.head (lib.attrValues column);
            refId = lib.elemAt refs i;
            format = "table";
            instant = true;
          }) columns;
          transformations = [
            {
              id = "merge";
              options = { };
            }
            {
              id = "organize";
              options = {
                excludeByName.Time = true;
                indexByName = lib.listToAttrs (
                  lib.imap0 (i: key: lib.nameValuePair key i) (keys ++ map field refs)
                );
                renameByName = lib.listToAttrs (
                  lib.imap0 (i: ref: lib.nameValuePair (field ref) (lib.elemAt names i)) refs
                );
              };
            }
          ];
          options.cellHeight = "sm";
        };

      # a percentage rounded up to two places: a nearly empty disk shows 0.01%, not 0.00412%
      percentOf = expr: "ceil(100 * 100 * (${expr})) / 100";

      # tunnels and bridges carry the same traffic a second time
      physical = ''device=~"en.*|eth.*|wl.*"'';

      scraped = hostsWith "metrics";
      disks = lib.concatMap (
        name:
        let
          data = scraped.${name};
          mounted = lib.filterAttrs (label: disk: label != "boot" && (disk.mounts or { }) != { }) data.disk;
        in
        [
          {
            host = name;
            label = "system";
            mountpoint = "/";
          }
        ]
        ++ lib.mapAttrsToList (label: disk: {
          host = name;
          inherit label;
          mountpoint = lib.head (lib.attrValues disk.mounts);
        }) mounted
      ) (lib.attrNames scraped);
      byDisk =
        metric:
        "max by (host, disk) (${
          lib.concatStringsSep " or " (
            map (
              disk:
              ''label_replace(${metric}{host="${disk.host}",mountpoint="${disk.mountpoint}"}, "disk", "${disk.label}", "", "")''
            ) disks
          )
        })";

      overview = [
        (
          table "System"
            [ "host" ]
            [
              { CPU = percentOf ''1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m]))''; }
              { GPU = percentOf "max by (host) (nvidia_gpu_utilization_percent) / 100"; }
              {
                Memory = percentOf "1 - sum by (host) (node_memory_MemAvailable_bytes) / sum by (host) (node_memory_MemTotal_bytes)";
              }
              # the hottest sensor, the GPU's included
              {
                Temperature = ''max by (host) ({__name__=~"node_hwmon_temp_celsius|nvidia_gpu_temperature_celsius"})'';
              }
            ]
          // {
            fieldConfig = {
              defaults = { };
              overrides = [
                (column "host" [ (property "displayName" "Host") ])
                (column "CPU" (percentLevel 70 90))
                (column "GPU" (percentLevel 70 90))
                (column "Memory" (percentLevel 80 90))
                (column "Temperature" (
                  [
                    (property "unit" "celsius")
                    (property "decimals" 0)
                  ]
                  ++ level 70 85
                ))
              ];
            };
          }
        )
        (
          table "Disks"
            [ "host" "disk" ]
            [
              { Size = byDisk "node_filesystem_size_bytes"; }
              { Used = "${byDisk "node_filesystem_size_bytes"} - ${byDisk "node_filesystem_avail_bytes"}"; }
              {
                "Used %" =
                  percentOf "1 - ${byDisk "node_filesystem_avail_bytes"} / ${byDisk "node_filesystem_size_bytes"}";
              }
            ]
          // {
            fieldConfig = {
              defaults = { };
              overrides = [
                (column "host" [ (property "displayName" "Host") ])
                (column "disk" [ (property "displayName" "Disk") ])
                (column "Size" [ (property "unit" "decbytes") ])
                (column "Used" [ (property "unit" "decbytes") ])
                (column "Used %" (percentLevel 70 85))
              ];
            };
          }
        )
      ];
      graphs = [
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
        (timeseries "Disk I/O" { unit = "Bps"; } [
          (query ''sum by (host) (rate(node_disk_read_bytes_total{device!~"loop.*|zram.*|dm-.*"}[5m]))'' "{{host}} read")
          (query ''sum by (host) (rate(node_disk_written_bytes_total{device!~"loop.*|zram.*|dm-.*"}[5m]))'' "{{host}} write")
        ])
      ];
      spaceUse = "max by (host, space) (axon_space_used_bytes)";
      spaceLimit = "max by (host, space) (axon_space_limit_bytes)";
      spaces = [
        (
          table "Spaces"
            [ "host" "space" ]
            [
              { Used = spaceUse; }
              { Limit = spaceLimit; }
              { "Use %" = percentOf "${spaceUse} / ${spaceLimit}"; }
            ]
          // {
            fieldConfig = {
              defaults = { };
              overrides = [
                (column "host" [ (property "displayName" "Host") ])
                (column "space" [ (property "displayName" "Space") ])
                # limits are powers of 1024
                (column "Used" [ (property "unit" "bytes") ])
                (column "Limit" [ (property "unit" "bytes") ])
                (column "Use %" (percentLevel 80 90))
              ];
            };
          }
        )
      ];
      # Postgres runs where a server lists files or forge, as in monitoring/metrics.nix
      postgres = lib.any (
        data:
        data.host.class == "server" && lib.intersectLists [ "files" "forge" ] data.host.features != [ ]
      ) (lib.attrValues scraped);
      ownDatabases = ''datname!~"postgres|template.*"'';
      # a dump's timer reports 0 until its first run
      dumped = ''label_replace(node_systemd_timer_last_trigger_seconds{name=~"postgresqlBackup-.+[.]timer"} > 0, "database", "$1", "name", "postgresqlBackup-(.+)[.]timer")'';
      databases = [
        (timeseries "Database size" { unit = "bytes"; } [
          (query "pg_database_size_bytes{${ownDatabases}}" "{{host}} {{datname}}")
        ])
        (timeseries "Database connections" { } [
          (query "pg_stat_database_numbackends{${ownDatabases}}" "{{host}} {{datname}}")
        ])
        (
          table "Dumps"
            [ "host" "database" ]
            [
              { Age = "max by (host, database) (time() - ${dumped})"; }
            ]
          // {
            fieldConfig = {
              defaults = { };
              overrides = [
                (column "host" [ (property "displayName" "Host") ])
                (column "database" [ (property "displayName" "Database") ])
                # nightly: amber after a missed night, red after two
                (column "Age" ([ (property "unit" "s") ] ++ level (36 * 3600) (60 * 3600)))
              ];
            };
          }
        )
      ];
      panels = overview ++ graphs ++ spaces ++ lib.optionals postgres databases;

      start = lib.toJSON {
        uid = "start";
        title = "Start page";
        time = {
          from = "now-24h";
          to = "now";
        };
        refresh = "1m";
        panels = lib.imap1 (
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

      dashboards = pkgs.writeTextDir "start.json" start;
    in
    {
      # ── service ────────
      services.grafana = {
        enable = true;
        # Grafana 13 downloads its data sources and Drilldown apps on start; declared, they come
        # from nixpkgs instead, and only these
        declarativePlugins = [
          pkgs.grafanaPlugins.grafana-lokiexplore-app
          pkgs.grafanaPlugins.grafana-metricsdrilldown-app
          pkgs.grafanaPlugins.loki
          pkgs.grafanaPlugins.prometheus
        ];
        settings = {
          server = {
            http_port = port;
            domain = name;
            root_url = "${origin}/";
          };
          security = {
            # the start page shows panels of the Start page dashboard in frames
            allow_embedding = true;
            admin_user = user.name;
            admin_password = "$__file{${config.sops.secrets."monitoring/password".path}}";
            secret_key = "$__file{${state}/secret_key}";
          };
          # read-only without its own login; the start page's frames need it
          "auth.anonymous".enabled = true;
          # info logs every query; the two filtered sources warn per poll and per expired cookie
          log = {
            level = "warn";
            filters = "search-manifest-watcher:error authn.service:error";
          };
          # no login attribute, so the login is the mail address and can't collide with the admin's
          "auth.generic_oauth" = lib.mkIf (sso.provider != null) {
            enabled = true;
            name = "Kanidm";
            client_id = client.id;
            client_secret = "$__file{${client.secret}}";
            scopes = "openid profile email groups";
            auth_url = sso.provider.authorize;
            token_url = sso.provider.token;
            api_url = sso.provider.userinfo client.id;
            use_pkce = true;
            use_refresh_token = true;
            role_attribute_path = "contains(groups[*], '${client.groupClaim}') && 'Admin' || 'Viewer'";
          };
        };
        provision = {
          datasources.settings.datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              uid = "prometheus";
              url = "http://127.0.0.1:${toString config.services.prometheus.port}";
              isDefault = true;
            }
            {
              name = "Loki";
              type = "loki";
              uid = "loki";
              url = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}";
              # Loki without auth still wants a tenant on some endpoints (Logs Drilldown's limits);
              # "fake" is the one it uses for all others
              jsonData.httpHeaderName1 = "X-Scope-OrgID";
              # from a file: a value written here directly draws a warning on every evaluation
              secureJsonData.httpHeaderValue1 = "$__file{${pkgs.writeText "loki-tenant" "fake"}}";
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

      # ── units ────────
      systemd.services.grafana.preStart = ''
        umask 077
        [ -e ${state}/secret_key ] || head -c 32 /dev/urandom | base64 -w0 >${state}/secret_key
      '';

      # ── secrets ────────
      sops.secrets."monitoring/password".owner = "grafana";

      # ── login ────────
      axon.sso.clients.grafana = {
        service = "grafana";
        landing = "${url}/login/generic_oauth";
        redirects = [ "${url}/login/generic_oauth" ];
        group = "admins";
      };

      # ── data ────────
      axon.persist.state.directories = [
        {
          directory = state;
          user = "grafana";
          group = "grafana";
          mode = "0700";
        }
      ];

      # ── registration ────────
      axon.services.grafana = {
        units = [ "grafana" ];
        route.port = port;
        dashboard = {
          name = "Grafana";
          group = "System";
          icon = "grafana.svg";
          # Loki's logs are the space monitoring fills
          space = "loki";
          # the overview tables come first in the dashboard, so their panel ids are 1 and 2
          instances = {
            Grafana = {
              description = "Dashboards and logs";
              group = "Infrastructure";
            };
          }
          // lib.listToAttrs (
            lib.imap1 (
              id: panel:
              lib.nameValuePair panel.title {
                description = "right now";
                link = "${origin}/d/start";
                widget = {
                  type = "iframe";
                  name = "grafana-${toString id}";
                  src = "${origin}/d-solo/start/start?panelId=${toString id}&theme=dark&refresh=1m";
                  classes = "h-60 sm:h-60 md:h-60 lg:h-60 xl:h-60 2xl:h-72";
                  allowScrolling = "no";
                };
              }
            ) overview
          );
        };
        backup.paths = [ state ];
      };
    };
}
