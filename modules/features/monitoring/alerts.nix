# Alert rules over Prometheus' metrics, and Alertmanager to mail them to srv-alert@ through the
# same SMTP account as notifications.nix: one mail when an alert fires, again every 12 hours
# while it lasts, and one when it's resolved. Silences are set in its UI at alerts.<domain>.
{
  flake.modules.nixos.monitoring =
    { config, ... }:
    let
      ph = config.sops.placeholder;
      port = 9093;

      rule = alert: expr: wait: summary: {
        inherit alert expr;
        for = wait;
        annotations.summary = summary;
      };
      days = 86400;
    in
    {
      services.prometheus = {
        rules = [
          (builtins.toJSON {
            groups = [
              {
                name = "axon";
                rules = [
                  (rule "HostDown" ''up{job="node",class="server"} == 0'' "5m" "unreachable for 5 minutes")
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
                  (rule "ServiceDown" ''probe_success{job="service"} == 0'' "2m"
                    "{{ $labels.service }} doesn't answer"
                  )
                  (rule "RouteDown" ''probe_success{job=~"route|guarded"} == 0'' "5m"
                    "{{ $labels.instance }} is not reachable as it should be"
                  )
                  (rule "CertificateExpiring"
                    ''probe_ssl_earliest_cert_expiry{job=~"route|guarded"} - time() < 14 * ${toString days}''
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
          webExternalUrl = "https://alerts.${config.axon.cluster.domain}";
          # $MAIL_* are filled in from the environment file at start
          environmentFile = config.sops.templates."alertmanager.env".path;
          configuration = {
            global = {
              smtp_smarthost = "smtp.protonmail.ch:587";
              smtp_from = "$MAIL_FROM";
              smtp_auth_username = "$MAIL_FROM";
              smtp_auth_password = "$MAIL_TOKEN";
            };
            route = {
              receiver = "mail";
              group_by = [
                "alertname"
                "host"
                "service"
              ];
              group_wait = "30s";
              group_interval = "5m";
              repeat_interval = "12h";
            };
            receivers = [
              {
                name = "mail";
                email_configs = [
                  {
                    to = config.axon.mail.alert;
                    send_resolved = true;
                    headers.Subject = ''[{{ .CommonLabels.host }}] {{ .CommonAnnotations.summary }}{{ if eq .Status "resolved" }} (resolved){{ end }}'';
                    # plain text, like the other mails
                    html = "";
                    text = ''
                      {{ range .Alerts }}{{ .Labels.alertname }} on {{ .Labels.host }}: {{ .Annotations.summary }}
                      since {{ .StartsAt.Local.Format "Mon 02.01. 15:04" }}{{ if eq .Status "resolved" }}, resolved {{ .EndsAt.Local.Format "Mon 02.01. 15:04" }}{{ end }}

                      {{ end }}'';
                  }
                ];
              }
            ];
          };
        };
      };

      sops.templates."alertmanager.env" = {
        content = ''
          MAIL_FROM=${ph."mail/user"}@${ph."mail/domain"}
          MAIL_TOKEN=${ph."mail/token"}
        '';
        restartUnits = [ "alertmanager.service" ];
      };

      axon.persist.directories = [
        {
          directory = "/var/lib/private/alertmanager";
          mode = "0700";
        }
      ];

      axon.services.alerts.route.port = port;
    };
}
