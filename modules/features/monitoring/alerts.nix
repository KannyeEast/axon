# Alert rules over Prometheus' metrics, and Alertmanager to mail them through axon.mail: one
# mail when an alert fires and again every 12 hours while it lasts; none when it's over. A
# failed service on any host listing metrics is one (UnitFailed), mailed by _unit-mail.py with the
# end of its log from Loki and a link to the rest. Watchdog always fires, so a mail comes once a
# week. Without an account alerts only show in Alertmanager's UI, at alerts.<domain> where
# silences are set too.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        cluster
        host
        mail
        routed
        services
        ;
      port = 9093;
      hook = 9096;
      grafana = services.grafana.route.url;
      downloads = lib.any (
        data: lib.elem "metrics" data.host.features && lib.elem "downloads" data.host.features
      ) (lib.attrValues cluster.hosts);

      rule = alert: expr: wait: summary: {
        inherit alert expr;
        for = wait;
        annotations.summary = summary;
      };

      # the page from axon.mail, by level. Watchdog always fires: its weekly mail is good news; a
      # Reminder (pushed by an n8n workflow) is news; the rest fail
      byLevel =
        {
          ok,
          info,
          fail,
        }:
        ''{{ if eq .CommonLabels.alertname "Watchdog" }}${ok}{{ else if eq .CommonLabels.alertname "Reminder" }}${info}{{ else }}${fail}{{ end }}'';
      level = field: byLevel (lib.mapAttrs (_: colors: colors.${field}) mail.levels);
      since = ''since {{ .StartsAt.Local.Format "Mon 02.01. 15:04" }}'';
      # an alert's unit in Logs Drilldown, from an hour before it fired. html/template escapes the
      # html part's values by itself; the text part's go through urlquery
      logs =
        escape:
        "${grafana}/a/grafana-lokiexplore-app/explore/unit/{{ ${escape ".Labels.unit"} }}/logs?var-filters=unit%7C%3D%7C{{ ${escape ".Labels.unit"} }}&var-filters=host%7C%3D%7C{{ ${escape ".Labels.host"} }}&from={{ (.StartsAt.Add -3600000000000).UnixMilli }}&to=now";
      htmlLogs = lib.replaceStrings [ "&" ] [ "&amp;" ] (logs lib.id);
      # an alert's links: its unit's logs where Grafana is routed, and its link annotation
      hasLinks = if routed then "or .Labels.unit .Annotations.link" else ".Annotations.link";
      button =
        href: text:
        ''<a href="${href}" style="display:inline-block;margin:0 8px 0 0;padding:11px 18px;border-radius:6px;background:#111827;font-size:14px;line-height:18px;font-weight:600;color:#FFFFFF;text-decoration:none;">${text}</a>'';
      buttons =
        lib.optionalString routed "{{ if .Labels.unit }}${button htmlLogs "View logs"}{{ end }}"
        + "{{ with .Annotations.link }}${button "{{ . }}" "Details"}{{ end }}";
      smallLinks =
        lib.optionalString routed ''{{ if .Labels.unit }} · <a href="${htmlLogs}" style="color:#111827;">Logs</a>{{ end }}''
        + ''{{ with .Annotations.link }} · <a href="{{ . }}" style="color:#111827;">Details</a>{{ end }}'';
      section = "margin:24px 0 0;padding:20px 0 0;border-top:1px solid #E5E7EB;";
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
                headers.Subject = "[{{ .CommonLabels.host }}] {{ or .CommonAnnotations.summary .CommonLabels.alertname }}";
                html =
                  lib.replaceStrings
                    [
                      "@preview@"
                      "@label@"
                      "@color@"
                      "@tint@"
                      "@bar@"
                      "@title@"
                      "@subtitle@"
                      "@footer@"
                      "@body@"
                    ]
                    [
                      "{{ .CommonLabels.alertname }} on {{ .CommonLabels.host }}{{ with .CommonAnnotations.summary }}: {{ . }}{{ end }}"
                      (byLevel {
                        ok = "WORKING";
                        info = "REMINDER";
                        fail = "FIRING";
                      })
                      (level "color")
                      (level "tint")
                      (level "bar")
                      "{{ .CommonLabels.alertname }}"
                      "{{ .CommonLabels.host }} · {{ with index .Alerts 0 }}${since}{{ end }}"
                      "Sent by ${host.name}"
                      ''
                        {{ if eq (len .Alerts) 1 }}{{ with index .Alerts 0 }}
                        <p style="margin:12px 0 0;font-size:15px;line-height:22px;color:#111827;">{{ .Annotations.summary }}</p>
                        {{ if ${hasLinks} }}<div style="${section}">${buttons}</div>{{ end }}
                        {{ end }}{{ else }}
                        <div style="${section}">
                        <div style="padding:0 0 14px;font-size:12px;line-height:16px;font-weight:700;letter-spacing:0.06em;color:#6B7280;">{{ len .Alerts }} {{ if eq .CommonLabels.alertname "Reminder" }}REMINDERS{{ else }}ALERTS{{ end }}</div>
                        {{ range .Alerts }}
                        <p style="margin:0;font-size:15px;line-height:22px;color:#111827;">{{ .Annotations.summary }}</p>
                        <p style="margin:0 0 12px;font-size:13px;line-height:20px;color:#6B7280;">${since}${smallLinks}</p>
                        {{ end }}
                        </div>
                        {{ end }}''
                    ]
                    mail.page;
                text = ''
                  {{ range .Alerts }}{{ .Labels.alertname }} on {{ .Labels.host }}: {{ .Annotations.summary }}
                  ${textLinks}${since}

                  {{ end }}'';
              }
            ];
          };

      unitMail = pkgs.writeText "unit-mail.json" (
        lib.toJSON {
          page = pkgs.writeText "page.html" mail.page;
          inherit (mail) levels port;
          smtp = mail.host;
          to = mail.alert;
          loki = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}";
          grafana = if routed then grafana else "";
          sender = host.name;
          listen = hook;
        }
      );
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
                  (rule "RouteDown" ''probe_success{job="route"} == 0'' "5m"
                    "{{ $labels.service }}: route unreachable"
                  )
                  (rule "CertificateExpiring" ''probe_ssl_earliest_cert_expiry{job="route"} - time() < 14 * 86400''
                    "0m"
                    "{{ $labels.service }} certificate expires in {{ $value | humanizeDuration }}"
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
                    "sabnzbd_queue_length > 0 and sabnzbd_paused == 0 and sabnzbd_speed_bps == 0"
                    "2h"
                    "{{ $value }} queued, nothing downloading"
                  )
                  # a hung post-processing keeps it paused, as does a pause that was forgotten
                  (rule "DownloadsPaused" "sabnzbd_queue_length > 0 and sabnzbd_paused == 1" "2h"
                    "{{ $value }} queued, paused"
                  )
                  # the apps' own health checks: indexers or download client failing, missing folders; their
                  # updates come with the system
                  (rule "ArrUnhealthy"
                    ''{__name__=~"(sonarr|radarr|prowlarr)_system_health_issues",type=~"warning|error",source!="UpdateCheck"} == 1''
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
              ]
              ++ lib.optional (mail != null) {
                matchers = [ ''alertname="UnitFailed"'' ];
                receiver = "unit";
              };
            };
            receivers = [
              receiver
            ]
            ++ lib.optional (mail != null) {
              name = "unit";
              webhook_configs = [
                {
                  url = "http://127.0.0.1:${toString hook}/";
                  send_resolved = false;
                }
              ];
            };
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
        restartUnits = [
          "alertmanager.service"
          "unit-mail.service"
        ];
      };

      systemd.services.unit-mail = lib.mkIf (mail != null) {
        description = "Mail failed units with their log";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          DynamicUser = true;
          Restart = "on-failure";
          EnvironmentFile = config.sops.templates."alertmanager.env".path;
          ExecStart = "${lib.getExe' pkgs.python3 "python3"} ${./_unit-mail.py} ${unitMail}";
        };
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
