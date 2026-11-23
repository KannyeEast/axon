# Alertmanager at alerts.<domain>: the alert rules over Prometheus, mailed to srv-alert@<domain>.
# Reach: tailnet, the gateway's login.
# In its UI only: silences, not backed up.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        domain
        host
        hostsWith
        mail
        registry
        routed
        services
        ;
      port = 9093;
      hook = 9096;
      n8n.url = "http://127.0.0.1:${toString config.services.n8n.environment.N8N_PORT}/webhook/alerts";
      grafana = services.grafana.route.url;
      # the rules of every feature a host listing metrics lists
      featureRules = lib.concatMap (feature: registry.${feature}.alerts) (
        lib.unique (lib.concatMap (data: data.host.features) (lib.attrValues (hostsWith "metrics")))
      );
      # its own local part, so a rule at the mailbox can file alerts away
      recipient = "srv-alert@${domain}";
      page = lib.readFile ./_page.html;
      levels = {
        ok = {
          color = "#15803D";
          tint = "#DCFCE7";
          bar = "#16A34A";
        };
        info = {
          color = "#1D4ED8";
          tint = "#DBEAFE";
          bar = "#2563EB";
        };
        fail = {
          color = "#B91C1C";
          tint = "#FEE2E2";
          bar = "#DC2626";
        };
      };

      rule = alert: expr: wait: summary: {
        inherit alert expr;
        for = wait;
        annotations.summary = summary;
      };

      # Watchdog always fires, so its weekly mail is good news; a Reminder (from n8n) is news
      byLevel =
        {
          ok,
          info,
          fail,
        }:
        ''{{ if eq .CommonLabels.alertname "Watchdog" }}${ok}{{ else if eq .CommonLabels.alertname "Reminder" }}${info}{{ else }}${fail}{{ end }}'';
      level = field: byLevel (lib.mapAttrs (_: colors: colors.${field}) levels);
      since = ''since {{ .StartsAt.Local.Format "Mon 02.01. 15:04" }}'';
      # html/template escapes the html part's values itself; the text part's need urlquery
      logs =
        escape:
        "${grafana}/a/grafana-lokiexplore-app/explore/unit/{{ ${escape ".Labels.unit"} }}/logs?var-filters=unit%7C%3D%7C{{ ${escape ".Labels.unit"} }}&var-filters=host%7C%3D%7C{{ ${escape ".Labels.host"} }}&from={{ (.StartsAt.Add -3600000000000).UnixMilli }}&to=now";
      htmlLogs = lib.replaceStrings [ "&" ] [ "&amp;" ] (logs lib.id);
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
                to = recipient;
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
                    page;
                text = ''
                  {{ range .Alerts }}{{ .Labels.alertname }} on {{ .Labels.host }}: {{ .Annotations.summary }}
                  ${textLinks}${since}

                  {{ end }}'';
              }
            ];
          };

      unitMail = pkgs.writeText "unit-mail.json" (
        lib.toJSON {
          page = pkgs.writeText "page.html" page;
          inherit levels;
          inherit (mail) port;
          smtp = mail.host;
          from = "alerts@${domain}";
          to = recipient;
          loki = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}";
          grafana = if routed then grafana else "";
          sender = host.name;
          listen = hook;
        }
      );
    in
    {
      # ── service ────────
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
                ++ featureRules;
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
          # a mail it has forgotten is sent again, so this must outlast the longest repeat
          extraFlags = [ "--data.retention=8760h" ];
          # $MAIL_* are filled in from the environment file at start
          environmentFile = if mail != null then config.sops.templates."alertmanager.env".path else null;
          configuration = {
            global = lib.optionalAttrs (mail != null) {
              smtp_smarthost = "${mail.host}:${toString mail.port}";
              smtp_from = "alerts@${domain}";
              smtp_auth_username = "$MAIL_LOGIN";
              smtp_auth_password = "$MAIL_TOKEN";
            };
            route = {
              receiver = receiver.name;
              group_by = [
                "alertname"
                "host"
              ];
              repeat_interval = "12h";
              routes = [
                {
                  matchers = [ ''alertname="Watchdog"'' ];
                  repeat_interval = "168h";
                }
                # a full disk stays full until freed: one mail, the next once it filled up again
                {
                  matchers = [ ''alertname=~"DiskFull|SpaceFull"'' ];
                  repeat_interval = "8760h";
                }
              ]
              ++ lib.optional (mail != null) {
                matchers = [ ''alertname="UnitFailed"'' ];
                receiver = "unit";
              };
            };
            # n8n answers 404, logged per alert, while no workflow listens on its alerts path
            receivers =
              map
                (
                  each:
                  each
                  // lib.optionalAttrs config.services.n8n.enable {
                    webhook_configs = each.webhook_configs or [ ] ++ [ n8n ];
                  }
                )
                (
                  [ receiver ]
                  ++ lib.optional (mail != null) {
                    name = "unit";
                    webhook_configs = [
                      {
                        url = "http://127.0.0.1:${toString hook}/";
                        send_resolved = false;
                      }
                    ];
                  }
                );
            inhibit_rules = [
              # a host that's gone takes everything else of it along, and one mail says so
              {
                source_matchers = [ ''alertname="HostDown"'' ];
                target_matchers = [ ''alertname!="HostDown"'' ];
                equal = [ "host" ];
              }
              # a service that's down takes its route with it
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

      # ── units ────────
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

      # ── secrets ────────
      sops.templates."alertmanager.env" = lib.mkIf (mail != null) {
        content = ''
          MAIL_LOGIN=${mail.login}
          MAIL_TOKEN=${mail.token}
        '';
        restartUnits = [
          "alertmanager.service"
          "unit-mail.service"
        ];
      };

      # ── data ────────
      axon.persist.state.directories = [
        "/var/lib/private/alertmanager"
      ];

      # ── registration ────────
      axon.services.alerts = {
        units = [ "alertmanager" ] ++ lib.optional (mail != null) "unit-mail";
        route.port = port;
      };

      # ── checks ────────
      warnings =
        lib.optional (mail == null)
          "hosts/${host.name}/host.toml: alerts only show in Alertmanager's UI; list the mail feature here to have them mailed";
    };
}
