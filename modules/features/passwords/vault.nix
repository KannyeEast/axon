# Vaultwarden at vault.<domain>: the family's password manager for the Bitwarden apps.
# Reach: tailnet, its own login, not the gateway's.
# In its UI only: accounts and their vaults, backed up through its nightly copy.
# By hand: invite the family from the admin page (vault/admin-token, an argon2 hash).
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
        ;
      inherit (config.axon.services.vault) route;
      port = 8222;
      backups = "${config.axon.spaces.backups.path}/vaultwarden";
      client = sso.clients.vaultwarden;
      hasAdmin = hasSecret "vault/admin-token";
      env =
        lib.optionalAttrs (mail != null) {
          SMTP_USERNAME = mail.login;
          SMTP_PASSWORD = mail.token;
        }
        // lib.optionalAttrs hasAdmin { ADMIN_TOKEN = config.sops.placeholder."vault/admin-token"; }
        // lib.optionalAttrs (sso.provider != null) { SSO_CLIENT_SECRET = client.placeholder; };
    in
    lib.mkIf (config.axon.host.class == "server") {
      # ── service ────────
      services.vaultwarden = {
        enable = true;
        backupDir = backups;
        config = {
          DOMAIN = route.origin;
          ROCKET_ADDRESS = route.address;
          ROCKET_PORT = port;
          SIGNUPS_ALLOWED = false;
          # cloudflared connects from 127.0.0.1; Cloudflare puts the client's address in this header
          IP_HEADER = "Cf-Connecting-IP";
          # the admin page's saved settings override these; in /run they go on restart, so without
          # vault/admin-token the admin page stays off
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
          # the master password alone is one factor; Kanidm's login brings the second
          SSO_ONLY = true;
          # its default lets the provider make accounts, past SIGNUPS_ALLOWED
          SSO_SIGNUPS_ALLOWED = false;
        };
        environmentFile = lib.mkIf (env != { }) config.sops.templates."vaultwarden.env".path;
      };

      # ── units ────────
      systemd.services.vaultwarden.serviceConfig.RuntimeDirectory = "vaultwarden";

      # ── secrets ────────
      sops.secrets."vault/admin-token" = lib.mkIf hasAdmin { };
      sops.templates."vaultwarden.env" = lib.mkIf (env != { }) {
        # single quotes keep the value verbatim: the argon2 hash is full of $
        content = lib.concatStrings (lib.mapAttrsToList (key: value: "${key}='${value}'\n") env);
        restartUnits = [ "vaultwarden.service" ];
      };

      # ── login ────────
      axon.sso.clients.vaultwarden = {
        service = "vault";
        redirects = [ "${route.url}/identity/connect/oidc-signin" ];
      };

      # ── data ────────
      axon.persist.state.directories = [ "/var/lib/vaultwarden" ];

      axon.spaces.backups.units = [ "backup-vaultwarden" ];

      # its module's tmpfiles rule may run before the space's mount at boot
      axon.folders.${backups} = {
        user = "vaultwarden";
        group = "vaultwarden";
        mode = "0770";
        units = [ "backup-vaultwarden" ];
      };

      # ── registration ────────
      axon.services.vault = {
        units = [
          "backup-vaultwarden"
          "vaultwarden"
        ];
        route = {
          inherit port;
          # the Bitwarden apps and extensions can't follow a browser login
          gate = false;
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
