# Vaultwarden at vault.<domain> on servers: the family's password manager for the Bitwarden apps.
# Public through the tunnel, guarded by its own login. Nobody signs up; accounts are invited from
# the admin page, on only while secrets.json holds vaultwarden/admin-token (an argon2 hash). With
# axon.mail it sends invitations and account mail. Its 23:00 copy is what gets backed up, on the
# data volume where a host has one.
{ lib, ... }:
{
  flake.modules.nixos.passwords =
    { config, ... }:
    let
      inherit (config.axon) mail volumes;
      inherit (config.axon.services.vault) route;
      ph = config.sops.placeholder;
      port = 8222;
      backups = "${volumes.data or "/var/backup"}/vaultwarden";
      hasAdmin = lib.hasAttrByPath [ "vaultwarden" "admin-token" ] config.axon.secrets;
      env =
        lib.optionalAttrs (mail != null) {
          SMTP_FROM = mail.address;
          SMTP_USERNAME = mail.address;
          SMTP_PASSWORD = mail.token;
        }
        // lib.optionalAttrs hasAdmin { ADMIN_TOKEN = ph."vaultwarden/admin-token"; };
    in
    lib.mkIf (config.axon.host.class == "server") {
      services.vaultwarden = {
        enable = true;
        backupDir = backups;
        config = {
          DOMAIN = route.origin;
          ROCKET_ADDRESS = "127.0.0.1";
          ROCKET_PORT = port;
          SIGNUPS_ALLOWED = false;
          # cloudflared connects from 127.0.0.1; Cloudflare puts the client's address in this header
          IP_HEADER = "Cf-Connecting-IP";
          # the admin page saves its settings here, and they override these on start; at runtime
          # only, so a restart brings back the Nix settings and an admin page without a token stays off
          CONFIG_FILE = "/run/vaultwarden/config.json";
        }
        // lib.optionalAttrs (mail != null) {
          SMTP_HOST = mail.host;
          SMTP_PORT = mail.port;
        };
        environmentFile = lib.mkIf (env != { }) config.sops.templates."vaultwarden.env".path;
      };

      sops.secrets."vaultwarden/admin-token" = lib.mkIf hasAdmin { };
      sops.templates."vaultwarden.env" = lib.mkIf (env != { }) {
        # single quotes keep the value verbatim: the argon2 hash is full of $
        content = lib.concatStrings (lib.mapAttrsToList (key: value: "${key}='${value}'\n") env);
        restartUnits = [ "vaultwarden.service" ];
      };

      systemd.services.vaultwarden.serviceConfig.RuntimeDirectory = "vaultwarden";
      # the copy lives on a data disk that may be missing at boot (nofail): never write to root instead
      systemd.services.backup-vaultwarden.unitConfig.RequiresMountsFor = [ backups ];

      axon.persist.state.directories = [
        {
          directory = "/var/lib/vaultwarden";
          user = "vaultwarden";
          group = "vaultwarden";
          mode = "0700";
        }
      ]
      ++ lib.optional (!volumes ? data) backups;

      axon.services.vault = {
        route = {
          inherit port;
          access = "open"; # Vaultwarden's own login
          public = true;
        };
        dashboard = {
          name = "Vaultwarden";
          group = "Files";
          description = "Passwords";
          icon = "vaultwarden.svg";
          monitor = "/alive";
        };
        backup = {
          paths = [ backups ];
          # favicons and temporary files the copy takes along
          exclude = [
            "${backups}/icon_cache"
            "${backups}/tmp"
          ];
        };
      };
    };
}
