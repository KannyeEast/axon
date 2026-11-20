# Alert rules over Prometheus' metrics, and Alertmanager to mail them through axon.mail: one
# mail when an alert fires, again every 12 hours while it lasts, and one when it's resolved. A
# failed service on any host listing metrics is one (UnitFailed); where Grafana is routed, a mail
# about a unit links to its logs in Logs Drilldown. Watchdog always fires, so a mail once a week
# shows that alerting works. Without an account alerts only show in Alertmanager's UI, at
# alerts.<domain> where silences are set too.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, ... }:
    let
      inherit (config.axon)
        cluster
        host
        mail
        routed
        services
        ;
      port = 9093;
      grafana = services.grafana.route.url;
      downloads = lib.any (
        data: lib.elem "metrics" data.host.features && lib.elem "downloads" data.host.features
      ) (lib.attrValues cluster.hosts);

      rule = alert: expr: wait: summary: {
        inherit alert expr;
        for = wait;
        annotations.summary = summary;
      };

      # the page from axon.mail; whether the alert is over is only known when it's sent. The
      # weekly Watchdog mail is good news, so it looks like a resolved one
      status =
        firing: resolved:
        ''{{ if or (eq .Status "resolved") (eq .CommonLabels.alertname "Watchdog") }}${resolved}{{ else }}${firing}{{ end }}'';
      level = field: status mail.levels.fail.${field} mail.levels.ok.${field};
      alertTimes = ''since {{ .StartsAt.Local.Format "Mon 02.01. 15:04" }}{{ if eq .Status "resolved" }}, resolved {{ .EndsAt.Local.Format "Mon 02.01. 15:04" }}{{ end }}'';
      # an alert's unit in Logs Drilldown, from an hour before it fired. html/template escapes the
      # html part's values by itself; the text part's go through urlquery
      logs =
        escape:
        "${grafana}/a/grafana-lokiexplore-app/explore/unit/{{ ${escape ".Labels.unit"} }}/logs?var-filters=unit%7C%3D%7C{{ ${escape ".Labels.unit"} }}&var-filters=host%7C%3D%7C{{ ${escape ".Labels.host"} }}&from={{ (.StartsAt.Add -3600000000000).UnixMilli }}&to=now";
      # below an alert's summary: its unit's logs where Grafana is routed, and its link annotation
      htmlLinks =
        lib.optionalString routed ''{{ if .Labels.unit }}<p style="margin:0 0 2px;font-size:14px;"><a href="${
          lib.replaceStrings [ "&" ] [ "&amp;" ] (logs lib.id)
        }">Logs of {{ .Labels.unit }}</a></p>{{ end }}''
        + ''{{ with .Annotations.link }}<p style="margin:0 0 2px;font-size:14px;"><a href="{{ . }}">{{ . }}</a></p>{{ end }}'';
      textLinks =
        lib.optionalString routed "{{ if .Labels.unit }}Logs: ${
          logs (field: "${field} | urlquery")
        }\n{{ end }}"
        + "{{ with .Annotations.link }}{{ . }}\n{{ end }}";

      receiver =
        if mail == null then
          { name = "none"; }
        else
          {
            name = "mail";
            email_configs = [
              {
                to = mail.alert;
                send_resolved = true;
                headers.Subject = ''[{{ .CommonLabels.host }}] {{ .CommonAnnotations.summary }}{{ if eq .Status "resolved" }} (resolved){{ end }}'';
                html =
                  lib.replaceStrings
                    [
                      "@label@"
                      "@color@"
                      "@tint@"
                      "@title@"
                      "@subtitle@"
                      "@footer@"
                      "@body@"
                    ]
                    [
                      ''{{ if eq .CommonLabels.alertname "Watchdog" }}Working{{ else }}${status "Firing" "Resolved"}{{ end }}''
                      (level "color")
                      (level "tint")
                      "<b>{{ .CommonLabels.alertname }}</b>"
                      "on {{ .CommonLabels.host }}"
                      "Sent by ${host.name}"
                      ''
                        {{ range .Alerts }}
                        <p style="margin:0 0 2px;font-weight:600;">{{ .Annotations.summary }}</p>
                        ${htmlLinks}
                        <p style="margin:0 0 14px;color:#6b7280;font-size:14px;">${alertTimes}</p>
                        {{ end }}''
                    ]
                    mail.page;
                text = ''
                  {{ range .Alerts }}{{ .Labels.alertname }} on {{ .Labels.host }}: {{ .Annotations.summary }}
                  ${textLinks}${alertTimes}

                  {{ end }}'';
              }
            ];
          };
    in
    {
      services.prometheus = {
        rules = [
          (lib.toJSON {
            groups = [
              {
                name = "axon";
                rules = [
                  (rule "HostDown" ''up{job="node",class="server"} == 0'' "5m" "unreachable")
                  (rule "ExporterDown" ''up{job!="node",class="server"} == 0'' "5m" "{{ $labels.job }} exporter down")
                  (rule "DiskFull"
                    ''1 - node_filesystem_avail_bytes{fstype!="tmpfs"} / node_filesystem_size_bytes > 0.85''
                    "15m"
                    "{{ $labels.mountpoint }} is {{ $value | humanizePercentage }} full"
                  )
                  (rule "CpuBusy" ''1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.9'' "15m"
                    "CPU at {{ $value | humanizePercentage }}"
                  )
                  (rule "MemoryLow" "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1" "10m"
                    "{{ $value | humanizePercentage }} memory free"
                  )
                  (rule "Hot" "node_hwmon_temp_celsius > 85" "10m"
                    "{{ $labels.chip }} {{ $labels.sensor }} at {{ $value }} °C"
                  )
                  (rule "DiskUnhealthy" "smartctl_device_smart_status != 1" "0m" "{{ $labels.device }} failing")
                  (rule "BtrfsErrors" "increase(node_btrfs_device_errors_total[1h]) > 0" "0m"
                    "{{ $labels.device }}: new {{ $labels.type }} errors"
                  )
                  (rule "ServiceDown" ''probe_success{job="service"} == 0'' "2m"
                    "{{ $labels.service }} doesn't answer"
                  )
                  (rule "RouteDown" ''probe_success{job="route"} == 0'' "5m" "{{ $labels.instance }} unreachable")
                  (rule "CertificateExpiring" ''probe_ssl_earliest_cert_expiry{job="route"} - time() < 14 * 86400''
                    "0m"
                    "{{ $labels.instance }} certificate expires in {{ $value | humanizeDuration }}"
                  )
                  # the node exporter names the unit in name; unit is the label its logs carry
                  (rule "UnitFailed"
                    ''label_replace(node_systemd_unit_state{state="failed"} == 1, "unit", "$1", "name", "(.+)")''
                    "0m"
                    "{{ $labels.unit }} failed"
                  )
                  (rule "SpaceFull" "axon_space_used_bytes / axon_space_limit_bytes > 0.9" "15m"
                    "{{ $labels.space }} {{ $value | humanizePercentage }} full"
                  )
                  {
                    alert = "Watchdog";
                    expr = "vector(1)";
                    # the subject names the host an alert is about
                    labels.host = host.name;
                    annotations = {
                      summary = "alerting works";
                    }
                    // lib.optionalAttrs routed { link = "${grafana}/d/start"; };
                  }
                ]
                ++ lib.optionals downloads [
                  (rule "DownloadsStalled"
                    "sabnzbd_queue_size > 0 and sabnzbd_paused == 0 and sabnzbd_queue_download_rate_bytes_per_second == 0"
                    "2h"
                    "{{ $value }} queued, nothing downloading"
                  )
                  # the apps' own health checks: indexers or download client failing, missing folders
                  (rule "ArrUnhealthy"
                    ''{__name__=~"(sonarr|radarr|prowlarr)_system_health_issues",type=~"warning|error"} == 1''
                    "1h"
                    "{{ $labels.job }}: {{ $labels.message }}"
                  )
                ];
              }
            ];
          })
        ];

        alertmanagers = [ { static_configs = [ { targets = [ "127.0.0.1:${toString port}" ]; } ]; } ];

        alertmanager = {
          enable = true;
          listenAddress = "127.0.0.1";
          inherit port;
          webExternalUrl = if config.axon.routed then config.axon.services.alerts.route.url else null;
          # Alertmanager forgets a sent mail after this long and then sends it again, so it must
          # outlast Watchdog's week
          extraFlags = [ "--data.retention=192h" ];
          # $MAIL_* are filled in from the environment file at start
          environmentFile = if mail != null then config.sops.templates."alertmanager.env".path else null;
          configuration = {
            global = lib.optionalAttrs (mail != null) {
              smtp_smarthost = "${mail.host}:${toString mail.port}";
              smtp_from = "$MAIL_FROM";
              smtp_auth_username = "$MAIL_FROM";
              smtp_auth_password = "$MAIL_TOKEN";
            };
            route = {
              receiver = receiver.name;
              group_by = [
                "alertname"
                "host"
                "service"
              ];
              repeat_interval = "12h";
              routes = [
                {
                  matchers = [ ''alertname="Watchdog"'' ];
                  repeat_interval = "168h";
                }
              ];
            };
            receivers = [ receiver ];
            # a service that's down takes its route with it, and one mail says so
            inhibit_rules = [
              {
                source_matchers = [ ''alertname="ServiceDown"'' ];
                target_matchers = [ ''alertname="RouteDown"'' ];
                equal = [
                  "host"
                  "service"
                ];
              }
            ];
          };
        };
      };

      sops.templates."alertmanager.env" = lib.mkIf (mail != null) {
        content = ''
          MAIL_FROM=${mail.address}
          MAIL_TOKEN=${mail.token}
        '';
        restartUnits = [ "alertmanager.service" ];
      };

      warnings =
        lib.optional (mail == null)
          "hosts/${host.name}/host.toml: alerts only show in Alertmanager's UI; list the mail feature here to have them mailed";

      axon.persist.state.directories = [
        {
          directory = "/var/lib/private/alertmanager";
          mode = "0700";
        }
      ];

      axon.services.alerts = {
        units = [ "alertmanager" ];
        route.port = port;
      };
    };
}
