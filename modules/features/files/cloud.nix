# Nextcloud at cloud.<domain>: file storage.
# Reach: public, its own login and axon.sso's where there is one.
# In its UI only: users, groups and shares, in its database and app state, backed up.
# By hand: `nextcloud-occ user:add <you> && nextcloud-occ group:adduser admin <you>`, then two-factor in the UI.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        domain
        mail
        routed
        services
        sso
        ;
      inherit (services.cloud) route;
      port = 8090;
      client = sso.clients.nextcloud;
      data = config.axon.spaces.nextcloud.path;
    in
    lib.mkIf (config.axon.host.class == "server") {
      # ── service ────────
      services.nextcloud = lib.mkMerge [
        {
          enable = true;
          # major versions upgrade one at a time: bump by one, switch, repeat
          package = pkgs.nextcloud35;
          hostName = route.name;
          https = routed;
          datadir = data;
          database.createLocally = true;
          maxUploadSize = "16G";
          config.dbtype = "pgsql";
          settings = {
            # the gateway and the tunnel deliver plain http on localhost; links must still say https
            trusted_proxies = [
              "127.0.0.1"
              "::1"
            ];
            overwriteprotocol = lib.mkIf routed "https";
            # what background jobs put in links; they have no request to read the address from
            "overwrite.cli.url" = route.origin;
            default_phone_region = "DE";
            serverid = 1; # unique per PHP server; there is one, but Nextcloud warns without it
            maintenance_window_start = 1; # 01:00 UTC
          };
          phpOptions = {
            "opcache.interned_strings_buffer" = "16";
            # the module ties this to maxUploadSize, but uploads stream
            memory_limit = lib.mkForce "1G";
          };
        }
        (lib.mkIf (sso.provider != null) {
          # this also closes the app store, which file storage alone doesn't need
          extraApps = { inherit (config.services.nextcloud.package.packages.apps) user_oidc; };
          # the provider answers on 127.0.0.1, a local address Nextcloud refuses without it
          settings.allow_local_remote_servers = true;
        })
        # without an account Nextcloud runs the same, but invites and password resets fail
        (lib.mkIf (mail != null) {
          settings = {
            mail_smtphost = mail.host;
            mail_smtpport = mail.port;
            mail_smtpauth = true;
            mail_from_address = "cloud";
            mail_domain = domain;
          };
          secretFile = config.sops.templates."nextcloud.json".path;
        })
      ];

      # nextcloud's nginx only on localhost; caddy owns 80/443
      services.nginx.virtualHosts.${route.name}.listen = [
        {
          addr = "127.0.0.1";
          inherit port;
        }
      ];

      # ── units ────────
      # updated on every setup run; --unique-uid=0 keeps the short name, so a login lands in the
      # account of that name; Nextcloud's own second factor is asked only on the password form
      systemd.services.nextcloud-setup.script = lib.mkIf (sso.provider != null) (
        lib.mkAfter ''
          nextcloud-occ user_oidc:provider Kanidm \
            --clientid=${client.id} \
            --clientsecret-file=${client.secret} \
            --discoveryuri=${client.issuer}/.well-known/openid-configuration \
            --mapping-uid=preferred_username \
            --unique-uid=0
        ''
      );

      # ── secrets ────────
      sops.templates."nextcloud.json" = lib.mkIf (mail != null) {
        owner = "nextcloud";
        content = lib.toJSON {
          mail_smtpname = mail.login;
          mail_smtppassword = mail.token;
        };
      };

      # ── login ────────
      axon.sso.clients.nextcloud = {
        service = "cloud";
        redirects = [ "${route.url}/apps/user_oidc/code" ];
      };

      # ── data ────────
      axon.spaces.nextcloud = {
        user = "nextcloud";
        group = "nextcloud";
        mode = "0750";
        units = [
          "nextcloud-cron"
          "nextcloud-setup"
          "nextcloud-update-db"
          "phpfpm-nextcloud"
        ];
      };

      axon.databases = [ "nextcloud" ];

      axon.persist.state.directories = [
        {
          directory = "/var/lib/nextcloud";
          user = "nextcloud";
          group = "nextcloud";
          mode = "0750";
        }
      ];

      # ── registration ────────
      axon.services.cloud = {
        # nginx is the module's front for PHP; nothing else here runs one
        units = [
          "nextcloud-cron"
          "nextcloud-setup"
          "nextcloud-update-db"
          "nginx"
          "phpfpm-nextcloud"
          "redis-nextcloud"
        ];
        route = {
          inherit port;
          # share links work without Tailscale
          public = true;
          # / redirects to https on this plain http port
          health = "/status.php";
        };
        dashboard = {
          name = "Nextcloud";
          group = "Files";
          description = "Files";
          icon = "nextcloud.svg";
          space = "nextcloud";
          widget = {
            type = "nextcloud";
            # four values make labels like "ACTIVE USERS" wrap, and the whole row grows with them
            fields = [
              "freespace"
              "numfiles"
              "activeusers"
            ];
          };
          key = true;
        };
        backup = {
          paths = [
            data
            "/var/lib/nextcloud"
          ];
          # rebuilt from the files
          exclude = [ "${data}/data/appdata_*/preview" ];
        };
      };
    };
}
