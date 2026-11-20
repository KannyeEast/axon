# Alloy ships this host's journal to Loki on every host listing monitoring (monitoring/logs.nix),
# with the labels host, unit, level, service_name and, for Docker containers, container. Without
# such a host it stays off. Its UI answers on localhost only.
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
          forward_to = [loki.write.monitoring.receiver]
          relabel_rules = loki.relabel.journal.rules
          labels = {host = ${lib.toJSON host.name}}
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
