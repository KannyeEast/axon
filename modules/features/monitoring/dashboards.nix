# Grafana at grafana.<domain>: graphs over Prometheus, with its data source and dashboards
# provisioned from here. Behind the gateway login, which Grafana trusts: the user the login names
# is signed in, and the host.toml user is Grafana's admin, with monitoring/password for the API.
# Without a gateway on this host it stays on localhost, with only its own login.
# Its secret key is made on first start and kept in its persisted state folder.
# The "Start page" dashboard is written here: two tables on top, each embedded on the gateway's
# start page (every host's CPU, GPU, memory and temperature; every disk's use), graphs over the
# last day below them.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    attrValues
    concatMap
    concatStringsSep
    elem
    elemAt
    filterAttrs
    head
    imap0
    imap1
    length
    listToAttrs
    mapAttrsToList
    nameValuePair
    take
    ;
in
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        cluster
        routed
        services
        user
        ;
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
      # a value coloured by how close it is to its limit; "–" where a host has none
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

      # instant values side by side, one row per label set: columns are { name = expr; } in order,
      # and every query aggregates down to the labels in keys
      table =
        title: keys: columns:
        let
          names = map (column: head (attrNames column)) columns;
          refs = take (length columns) [
            "A"
            "B"
            "C"
            "D"
          ];
        in
        {
          type = "table";
          inherit title;
          targets = imap0 (i: column: {
            expr = head (attrValues column);
            refId = elemAt refs i;
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
                indexByName = listToAttrs (
                  imap0 (i: key: nameValuePair key i) (keys ++ map (ref: "Value #${ref}") refs)
                );
                renameByName = listToAttrs (imap0 (i: ref: nameValuePair "Value #${ref}" (elemAt names i)) refs);
              };
            }
          ];
          options.cellHeight = "sm";
        };

      # a percentage rounded up to two places: a nearly empty disk shows 0.01%, not 0.00412%
      percentOf = expr: "ceil(100 * 100 * (${expr})) / 100";

      # tunnels and bridges carry the same traffic a second time
      physical = ''device=~"en.*|eth.*|wl.*"'';

      # every disk of every scraped host, by its host.toml label: the boot disk as "system" through
      # /, any other through its first mount
      scraped = filterAttrs (_: data: elem "metrics" data.host.features) cluster.hosts;
      disks = concatMap (
        name:
        let
          data = scraped.${name};
          mounted = filterAttrs (label: disk: label != "boot" && (disk.mounts or { }) != { }) data.disk;
        in
        [
          {
            host = name;
            label = "system";
            mountpoint = "/";
          }
        ]
        ++ mapAttrsToList (label: disk: {
          host = name;
          inherit label;
          mountpoint = head (attrValues disk.mounts);
        }) mounted
      ) (attrNames scraped);
      byDisk =
        metric:
        "max by (host, disk) (${
          concatStringsSep " or " (
            map (
              disk:
              ''label_replace(${metric}{host="${disk.host}",mountpoint="${disk.mountpoint}"}, "disk", "${disk.label}", "", "")''
            ) disks
          )
        })";

      # the start page's tables, then the graphs
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
      # two per row, in this order
      panels = overview ++ graphs;

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

      dashboards = pkgs.writeTextDir "start.json" start;
    in
    {
      services.grafana = {
        enable = true;
        settings = {
          server = {
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

      axon.persist.state.directories = [
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
          # the overview tables come first in the dashboard, so their panel ids are 1 and 2
          instances = listToAttrs (
            imap1 (
              id: panel:
              nameValuePair panel.title {
                description = "right now";
                link = "${url}/d/start";
                widget = {
                  type = "iframe";
                  name = "grafana-${toString id}";
                  src = "${url}/d-solo/start/start?panelId=${toString id}&theme=dark&refresh=1m";
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
