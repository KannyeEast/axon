# Alert rules over Prometheus' metrics, and Alertmanager to mail them through axon.mail: one
# mail when an alert fires, again every 12 hours while it lasts, and one when it's resolved.
# Without an account they only show in its UI, at alerts.<domain> where silences are set too.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, ... }:
    let
      inherit (config.axon) host mail;
      port = 9093;

      rule = alert: expr: wait: summary: {
        inherit alert expr;
        for = wait;
        annotations.summary = summary;
      };

      # the same page as the other mails; whether the alert is over is only known when it's sent
      status =
        firing: resolved: ''{{ if eq .Status "resolved" }}${resolved}{{ else }}${firing}{{ end }}'';
      level = field: status mail.levels.fail.${field} mail.levels.ok.${field};
      alertTimes = ''since {{ .StartsAt.Local.Format "Mon 02.01. 15:04" }}{{ if eq .Status "resolved" }}, resolved {{ .EndsAt.Local.Format "Mon 02.01. 15:04" }}{{ end }}'';

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
                      (status "Firing" "Resolved")
                      (level "color")
                      (level "tint")
                      "<b>{{ .CommonLabels.alertname }}</b>"
                      "on {{ .CommonLabels.host }}"
                      "Sent by ${host.name}"
                      ''
                        {{ range .Alerts }}
                        <p style="margin:0 0 2px;font-weight:600;">{{ .Annotations.summary }}</p>
                        <p style="margin:0 0 14px;color:#6b7280;font-size:14px;">${alertTimes}</p>
                        {{ end }}''
                    ]
                    mail.page;
                text = ''
                  {{ range .Alerts }}{{ .Labels.alertname }} on {{ .Labels.host }}: {{ .Annotations.summary }}
                  ${alertTimes}

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
                  (rule "HostDown" ''up{job="node",class="server"} == 0'' "5m" "unreachable for 5 minutes")
                  (rule "ExporterDown" ''up{job!="node",class="server"} == 0'' "5m"
                    "the {{ $labels.job }} exporter doesn't answer"
                  )
                  (rule "DiskFull"
                    ''1 - node_filesystem_avail_bytes{fstype!="tmpfs"} / node_filesystem_size_bytes > 0.85''
                    "15m"
                    "{{ $labels.mountpoint }} is {{ $value | humanizePercentage }} full"
                  )
                  (rule "CpuBusy" ''1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.9'' "15m"
                    "CPU at {{ $value | humanizePercentage }} for 15 minutes"
                  )
                  (rule "MemoryLow" "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1" "10m"
                    "only {{ $value | humanizePercentage }} of memory available"
                  )
                  (rule "Hot" "node_hwmon_temp_celsius > 85" "10m"
                    "{{ $labels.chip }} {{ $labels.sensor }} at {{ $value }} °C"
                  )
                  (rule "DiskUnhealthy" "smartctl_device_smart_status != 1" "0m"
                    "SMART reports {{ $labels.device }} as failing"
                  )
                  (rule "BtrfsErrors" "increase(node_btrfs_device_errors_total[1h]) > 0" "0m"
                    "{{ $labels.device }} has new {{ $labels.type }} errors"
                  )
                  (rule "ServiceDown" ''probe_success{job="service"} == 0'' "2m"
                    "{{ $labels.service }} doesn't answer"
                  )
                  (rule "RouteDown" ''probe_success{job=~"route|guarded"} == 0'' "5m"
                    "{{ $labels.instance }} is not reachable as it should be"
                  )
                  (rule "CertificateExpiring"
                    ''probe_ssl_earliest_cert_expiry{job=~"route|guarded"} - time() < 14 * 86400''
                    "0m"
                    "the certificate of {{ $labels.instance }} expires in {{ $value | humanizeDuration }}"
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

      axon.services.alerts.route.port = port;
    };
}
