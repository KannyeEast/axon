# Home Assistant at ha.<domain>: the household's hub, with the Companion app on the phones.
# Reach: tailnet, its own login (TOTP per user, a ban after failed logins), not the gateway's.
# In its UI only: its whole configuration, backed up with its state folder.
{
  flake.modules.nixos.family =
    {
      config,
      lib,
      pkgs,
      ...
    }:
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
      '';
      # HA's store for Settings > System > Network: an http: block in the YAML is only a trial that
      # reverts unless confirmed in the UI within five minutes; the store takes every field
      network = {
        server_host = [ "127.0.0.1" ];
        server_port = port;
        cors_allowed_origins = [ "https://cast.home-assistant.io" ];
        use_x_forwarded_for = true;
        trusted_proxies = [ "127.0.0.1/32" ];
        login_attempts_threshold = 5;
        ip_ban_enabled = true;
        ssl_profile = "intermediate_v6";
        use_x_frame_options = true;
        created_at = "1970-01-01T00:00:00+00:00";
        error = null;
        error_message = null;
      };
      networkStore = pkgs.writeText "http" (
        lib.toJSON {
          version = 3;
          minor_version = 1;
          key = "http";
          data = {
            stable = network;
            pending = null;
            yaml_migration_done = true;
          };
        }
      );
      seeding = pkgs.writeShellScript "home-assistant-seed" ''
        cd ${state}
        [ -e configuration.yaml ] && exit 0
        install -m 0644 ${seed} configuration.yaml
        install -D -m 0600 ${networkStore} .storage/http
        echo '[]' > automations.yaml
        echo '{}' > scripts.yaml
        echo '[]' > scenes.yaml
        mkdir -p themes
      '';
    in
    {
      virtualisation.oci-containers.containers.home-assistant = {
        image = "ghcr.io/home-assistant/home-assistant:2026.11.2@sha256:493a07e8f6530fc640223f4a0a5248f20a61ca2f718bb1d31efbf08a2c5ea28f";
        # finds devices on the network by broadcast
        networks = [ "host" ];
        environment.TZ = config.axon.locale.timezone;
        volumes = [ "${state}:/config" ];
      };

      systemd.services.docker-home-assistant.serviceConfig.ExecStartPre = [ "${seeding}" ];

      axon.persist.state.directories = [
        {
          directory = state;
          mode = "0700";
        }
      ];

      axon.services.ha = {
        units = [ "docker-home-assistant" ];
        # its log entries' first line; a traceback follows it
        logStart = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}";
        route = {
          inherit port;
          # the Companion app can't follow the gateway's browser login; HA's own login guards it
          gate = false;
        };
        dashboard = {
          name = "Home Assistant";
          group = "Home";
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
