# Home Assistant at ha.<domain>: the household's hub, with the Companion app on the phones.
# Reach: tailnet, its own login (TOTP per user, a ban after failed logins), not the gateway's.
# In its UI only: its whole configuration, backed up with its state folder.
{ lib, ... }:
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
    in
    {
      # ── service ────────
      virtualisation.oci-containers.containers.home-assistant = {
        image = "ghcr.io/home-assistant/home-assistant:2026.11.3@sha256:24e541ddae5818bf8eb27898b9ba00d0c344a655aa5097e9e9bd4b19356be847";
        # finds devices on the network by broadcast
        networks = [ "host" ];
        environment.TZ = config.axon.locale.timezone;
        volumes = [ "${state}:/config" ];
      };

      # ── units ────────
      # a first configuration, each file only while it is missing; HA edits them from then on
      systemd.tmpfiles.settings.home-assistant = {
        "${state}/configuration.yaml".C = {
          mode = "0644";
          argument = "${seed}";
        };
        "${state}/.storage".d = { };
        "${state}/.storage/http".C = {
          mode = "0600";
          argument = "${networkStore}";
        };
        "${state}/automations.yaml".f.argument = "[]";
        "${state}/scripts.yaml".f.argument = "{}";
        "${state}/scenes.yaml".f.argument = "[]";
        "${state}/themes".d = { };
      };
      # the appdata space may mount after tmpfiles ran at boot
      systemd.services.docker-home-assistant.serviceConfig.ExecStartPre = [
        "${config.systemd.package}/bin/systemd-tmpfiles --create --prefix=${state}"
      ];

      # ── data ────────
      axon.persist.state.directories = [
        {
          directory = state;
          mode = "0700";
        }
      ];

      # ── registration ────────
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
