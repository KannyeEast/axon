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

      receiver =
        if mail == null then
          { name = "none"; }
        else
          {
            name = "mail";
            webhook_configs = [
              {
                url = "http://127.0.0.1:${toString hook}/";
                send_resolved = false;
              }
            ];
          };

      alertMail = pkgs.writeText "alert-mail.json" (
        lib.toJSON {
          page = ./_page.html;
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
                  # stays firing down to 85%, so it does not flap around 90%
                  (rule "SpaceFull"
                    ''axon_space_used_bytes / axon_space_limit_bytes > 0.9 or (axon_space_used_bytes / axon_space_limit_bytes > 0.85 and on(host, space) ALERTS{alertname="SpaceFull",alertstate="firing"})''
                    "15m"
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
              # alert-mail can't mail its own failure, so Alertmanager's plain mail does
              ++ lib.optional (mail != null) {
                matchers = [
                  ''alertname="UnitFailed"''
                  ''unit="alert-mail.service"''
                ];
                receiver = "fallback";
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
                    name = "fallback";
                    email_configs = [ { to = recipient; } ];
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
      # not email_configs: one renderer for every mail, and a failed unit's log from Loki
      systemd.services.alert-mail = lib.mkIf (mail != null) {
        description = "Mail alerts";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          DynamicUser = true;
          Restart = "on-failure";
          EnvironmentFile = config.sops.templates."alertmanager.env".path;
          ExecStart = "${lib.getExe' pkgs.python3 "python3"} ${./_alert-mail.py} ${alertMail}";
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
          "alert-mail.service"
        ];
      };

      # ── data ────────
      axon.persist.state.directories = [
        "/var/lib/private/alertmanager"
      ];

      # ── registration ────────
      axon.services.alerts = {
        units = [ "alertmanager" ] ++ lib.optional (mail != null) "alert-mail";
        route.port = port;
      };

      # ── checks ────────
      warnings =
        lib.optional (mail == null)
          "hosts/${host.name}/host.toml: alerts only show in Alertmanager's UI; list the mail feature here to have them mailed";
    };
}
