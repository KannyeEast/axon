# Alloy ships this host's journal to Loki on every host listing monitoring (monitoring/logs.nix),
# with the labels host, unit, level, service_name and, for Docker containers, container. Without
# such a host it stays off. Its UI answers on localhost only.
# level is journald's priority keyword. What a program prints to stdout lands as info, so for
# those lines it comes from the line itself where that names one ([error], level=warn, ERROR); so
# for a container's stderr, which Docker marks err.
# Where a service declares logStart, the lines that follow an entry's first one (a stack trace)
# join it, so it is one entry with the first line's level.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, pkgs, ... }:
    let
      inherit (config.axon) cluster host services;
      containers = config.virtualisation.oci-containers;
      # Loki's port on the monitoring hosts
      port = 3100;
      monitors = lib.attrNames (
        lib.filterAttrs (_: data: lib.elem "monitoring" data.host.features) cluster.hosts
      );
      address = name: if name == host.name then "127.0.0.1" else name;

      # Docker's journald driver logs each container line with CONTAINER_NAME; oci-containers runs
      # `docker run` attached in the container's unit, which logs the same lines a second time.
      # That unit's output is dropped, the docker CLI's own errors with it (journalctl -u keeps them)
      attached = lib.optionals (containers.backend == "docker") (
        lib.mapAttrsToList (_: container: "${container.serviceName}.service") containers.containers
      );

      copy = source: target: ''
        rule {
          source_labels = [${lib.toJSON source}]
          target_label = ${lib.toJSON target}
        }
      '';

      # service_name, the rows of Grafana's Logs Drilldown: the program, overridden by the unit
      # without instance and .service, by the container, and last by the axon.services entry the
      # unit or container belongs to
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

      # journald's keywords and how programs write them; the short forms count only in brackets or
      # after level=, since words like ERR and INF also turn up in plain text
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
      # the first of level=<word> or "level":"<word>", [word], or WORD in capitals
      named = ''(?i:\b(?:level|lvl|severity)"?\s*[=:]\s*"?)(?P<a>[A-Za-z]+)|\[(?P<b>(?i:${any}))\]|\b(?P<c>${long})\b'';
      keyword = ''{{- $levels := dict${
        lib.concatStrings (
          lib.mapAttrsToList (
            level: names: lib.concatMapStrings (name: " \"${name}\" \"${level}\"") names
          ) levels
        )
      } -}}{{- with coalesce .a .b .c -}}{{- get $levels (lower .) | default "info" -}}{{- else -}}info{{- end -}}'';

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
            # Docker's journald driver marks all of a container's stderr as err, and some (Home
            # Assistant) print every line there
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
        {
          directory = "/var/lib/private/alloy";
          mode = "0700";
        }
      ];
    };
}
