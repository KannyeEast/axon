# Home Assistant at ha.<domain>, tailnet only: the household's hub, with the Companion app on the
# phones. The official container on the host's network, listening on 127.0.0.1. Its configuration
# is HA's own, made in its UI; a first one is seeded only when none exists, with what the gateway
# needs. The image runs as root inside: its process supervisor requires it.
{
  flake.modules.nixos.family =
    { config, pkgs, ... }:
    let
      port = 8123;
      state = "/var/lib/home-assistant";

      seed = pkgs.writeText "configuration.yaml" ''
        default_config:

        frontend:
          themes: !include_dir_merge_named themes

        automation: !include automations.yaml
        script: !include scripts.yaml
        scene: !include scenes.yaml

        http:
          server_host: 127.0.0.1
          server_port: ${toString port}
          use_x_forwarded_for: true
          trusted_proxies:
            - 127.0.0.1
      '';
      seeding = pkgs.writeShellScript "home-assistant-seed" ''
        cd ${state}
        [ -e configuration.yaml ] && exit 0
        install -m 0644 ${seed} configuration.yaml
        echo '[]' > automations.yaml
        echo '{}' > scripts.yaml
        echo '[]' > scenes.yaml
        mkdir -p themes
      '';
    in
    {
      virtualisation.oci-containers.containers.home-assistant = {
        image = "ghcr.io/home-assistant/home-assistant:2026.11.1@sha256:6785d1eca68747a524c156faae1b139ed415c07357386ae6fe17291986e59e82";
        # finds devices on the network by broadcast
        networks = [ "host" ];
        environment.TZ = config.axon.locale.timezone;
        volumes = [ "${state}:/config" ];
      };

      systemd.services.docker-home-assistant.serviceConfig.ExecStartPre = [ "+${seeding}" ];

      axon.persist.state.directories = [
        {
          directory = state;
          mode = "0700";
        }
      ];

      axon.services.ha = {
        route.port = port;
        dashboard = {
          name = "Home Assistant";
          group = "Files";
          description = "Household";
          icon = "home-assistant.svg";
        };
        backup = {
          paths = [ state ];
          # the recorder's history, rebuilt as it goes
          exclude = [ "${state}/home-assistant_v2.db*" ];
        };
      };
    };
}
