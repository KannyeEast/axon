# Alloy ships this host's journal to Loki on the monitoring hosts, labelled host, unit, level,
# service_name and container; an info line's level comes from the line where it names one.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host hostsWith services;
      # Loki's port on the monitoring hosts
      port = 3100;
      containers = config.virtualisation.oci-containers;
      monitors = lib.attrNames (hostsWith "monitoring");
      address = name: if name == host.name then "127.0.0.1" else name;

      # the attached `docker run` in a container's unit logs each line a second time; dropped, the
      # docker CLI's own errors go with it (journalctl -u keeps them)
      attached = lib.optionals (containers.backend == "docker") (
        lib.mapAttrsToList (_: container: "${container.serviceName}.service") containers.containers
      );

      copy = source: target: ''
        rule {
          source_labels = [${lib.toJSON source}]
          target_label = ${lib.toJSON target}
        }
      '';

      # service_name: the rows of Grafana's Logs Drilldown
      derive = source: regex: ''
        rule {
          source_labels = [${lib.toJSON source}]
          regex = ${lib.toJSON regex}
          target_label = "service_name"
        }
      '';
      assign = source: values: service: ''
        rule {
          source_labels = [${lib.toJSON source}]
          regex = ${lib.toJSON "(${lib.concatMapStringsSep "|" lib.escapeRegex values})"}
          target_label = "service_name"
          replacement = ${lib.toJSON service}
        }
      '';
      containersOf =
        data:
        lib.attrNames (
          lib.filterAttrs (_: container: lib.elem container.serviceName data.units) containers.containers
        );

      # short forms count only in brackets or after level=: ERR and INF turn up in plain text
      levels = {
        emerg = [
          "emerg"
          "emergency"
        ];
        alert = [ "alert" ];
        crit = [
          "crit"
          "critical"
          "fatal"
          "ftl"
          "panic"
        ];
        err = [
          "err"
          "eror"
          "error"
        ];
        warning = [
          "warn"
          "warning"
          "wrn"
        ];
        notice = [ "notice" ];
        info = [
          "info"
          "inf"
          "information"
        ];
        debug = [
          "debug"
          "dbg"
          "dbug"
          "trace"
          "trc"
          "verbose"
          "vrb"
        ];
      };
      tokens = lib.sort (a: b: lib.stringLength a > lib.stringLength b) (
        lib.concatLists (lib.attrValues levels)
      );
      any = lib.concatStringsSep "|" tokens;
      long = lib.concatStringsSep "|" (
        map lib.toUpper (lib.filter (token: lib.stringLength token > 3) tokens)
      );
      # level=<word>, "level":"<word>", [word], WORD, or a short form after a timestamp (zerolog)
      named = ''(?i:\b(?:level|lvl|severity)"?\s*[=:]\s*"?)(?P<a>[A-Za-z]+)|\[(?P<b>(?i:${any}))\]|\b(?P<c>${long})\b|^\d{4}-\d{2}-\d{2}T\S+ (?P<d>(?i:${any}))\b'';
      keyword = ''{{- $levels := dict${
        lib.concatStrings (
          lib.mapAttrsToList (
            level: names: lib.concatMapStrings (name: " \"${name}\" \"${level}\"") names
          ) levels
        )
      } -}}{{- with coalesce .a .b .c .d -}}{{- get $levels (lower .) | default "info" -}}{{- else -}}info{{- end -}}'';

      source = pkgs.writeText "config.alloy" ''
        loki.relabel "journal" {
          forward_to = []
        ${lib.optionalString (attached != [ ]) ''
          rule {
            source_labels = ["__journal__systemd_unit"]
            regex = ${lib.toJSON "(${lib.concatMapStringsSep "|" lib.escapeRegex attached})"}
            action = "drop"
          }
        ''}
        ${copy "__journal__systemd_unit" "unit"}
          // a desktop's user services all run under user@<uid>.service; their own unit is this one
          rule {
            source_labels = ["__journal__systemd_user_unit"]
            regex = "(.+)"
            target_label = "unit"
          }
          // systemd's own lines about a unit count as the unit's, as in journalctl -u
          rule {
            source_labels = ["__journal_unit"]
            regex = "(.+)"
            target_label = "unit"
          }
        ${copy "__journal_priority_keyword" "level"}
        ${copy "__journal_container_name" "container"}
        ${copy "__journal_syslog_identifier" "identifier"}
        ${derive "__journal_syslog_identifier" "(.+)"}
        ${derive "unit" "([^@]+)(@.*)?\\.service"}
        ${derive "container" "(.+)"}
        ${lib.concatStrings (
          lib.mapAttrsToList (
            service: data:
            lib.optionalString (data.units != [ ]) (
              assign "unit" (map (unit: "${unit}.service") data.units) service
            )
            + lib.optionalString (containersOf data != [ ]) (assign "container" (containersOf data) service)
          ) services
        )}
        }

        loki.source.journal "journal" {
          forward_to = [loki.process.level.receiver]
          relabel_rules = loki.relabel.journal.rules
          labels = {host = ${lib.toJSON host.name}}
        }

        loki.process "level" {
          forward_to = [loki.write.monitoring.receiver]

          // systemd's lines about a job that ran fine (timers every few minutes make thousands a
          // day); its lines about failures stay
          stage.match {
            selector = "{identifier=\"systemd\"}"
            stage.drop {
              expression = ${lib.toJSON "^(Starting .+\\.\\.\\.|Started .+\\.|Finished .+\\.|.+: Deactivated successfully\\.|.+: Consumed .+)$"}
              drop_counter_reason = "systemd_routine"
            }
          }
          stage.label_drop {
            values = ["identifier"]
          }

          // terminal colours some programs print into the journal too; they hide the level
          stage.replace {
            expression = ${lib.toJSON "(\\x1b\\[[0-9;]*m)"}
            replace = ""
          }
        ${lib.concatStrings (
          lib.mapAttrsToList (service: data: ''
            stage.match {
              selector = ${lib.toJSON "{service_name=\"${service}\"}"}
              stage.multiline {
                firstline = ${lib.toJSON data.logStart}
              }
            }
          '') (lib.filterAttrs (_: data: data.logStart != null) services)
        )}

        ${lib.concatMapStrings
          (selector: ''
            stage.match {
              selector = ${lib.toJSON selector}

              stage.regex {
                expression = ${lib.toJSON named}
              }
              stage.template {
                source = "level"
                template = ${lib.toJSON keyword}
              }
              stage.labels {
                values = {level = ""}
              }
            }
          '')
          [
            "{level=\"info\"}"
            # Docker marks a container's stderr err; some (Home Assistant) print every line there
            "{level=\"err\", container=~\".+\"}"
          ]
        }
        }

        loki.write "monitoring" {
        ${lib.concatMapStrings (name: ''
          endpoint {
            url = ${lib.toJSON "http://${address name}:${toString port}/loki/api/v1/push"}
          }
        '') monitors}
        }
      '';
    in
    lib.mkIf (monitors != [ ]) {
      services.alloy = {
        enable = true;
        extraFlags = [ "--disable-reporting" ];
      };

      # checked when built: Alloy keeps running the old config when a reload fails
      environment.etc."alloy/config.alloy".source =
        pkgs.runCommand "config.alloy" { nativeBuildInputs = [ config.services.alloy.package ]; }
          ''
            alloy validate ${source}
            alloy fmt ${source} >$out
          '';

      axon.persist.state.directories = [
        "/var/lib/private/alloy"
      ];
    };
}
