# Vaultwarden at vault.<domain>: the family's password manager for the Bitwarden apps.
# Reach: public, its own login.
# In its UI only: accounts and their vaults, backed up through its nightly copy.
# By hand: invite the family from the admin page (vaultwarden/admin-token, an argon2 hash).
{ lib, ... }:
{
  flake.modules.nixos.passwords =
    { config, ... }:
    let
      inherit (config.axon)
        domain
        hasSecret
        mail
        sso
        volumes
        ;
      inherit (config.axon.services.vault) route;
      client = sso.clients.vaultwarden;
      ph = config.sops.placeholder;
      port = 8222;
      backups = "${volumes.data or "/var/backup"}/vaultwarden";
      hasAdmin = hasSecret "vaultwarden/admin-token";
      env =
        lib.optionalAttrs (mail != null) {
          SMTP_USERNAME = mail.login;
          SMTP_PASSWORD = mail.token;
        }
        // lib.optionalAttrs hasAdmin { ADMIN_TOKEN = ph."vaultwarden/admin-token"; }
        // lib.optionalAttrs (sso.provider != null) { SSO_CLIENT_SECRET = ph."sso/${client.id}"; };
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
          # the admin page's saved settings override these; in /run they go on restart, so without
          # vaultwarden/admin-token the admin page stays off
          CONFIG_FILE = "/run/vaultwarden/config.json";
        }
        // lib.optionalAttrs (mail != null) {
          SMTP_HOST = mail.host;
          SMTP_PORT = mail.port;
          SMTP_FROM = "vault@${domain}";
        }
        // lib.optionalAttrs (sso.provider != null) {
          SSO_ENABLED = true;
          SSO_AUTHORITY = client.issuer;
          SSO_CLIENT_ID = client.id;
          # its default lets the provider make accounts, past SIGNUPS_ALLOWED
          SSO_SIGNUPS_ALLOWED = false;
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
      # the copy is on a data disk that may be missing at boot (nofail): never write to root instead
      systemd.services.backup-vaultwarden.unitConfig.RequiresMountsFor = [ backups ];

      axon.sso.clients.vaultwarden = {
        service = "vault";
        redirects = [ "${route.url}/identity/connect/oidc-signin" ];
      };

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
        units = [
          "backup-vaultwarden"
          "vaultwarden"
        ];
        route = {
          inherit port;
          public = true;
          health = "/alive";
        };
        dashboard = {
          name = "Vaultwarden";
          group = "Files";
          description = "Passwords";
          icon = "vaultwarden.svg";
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
