# Nextcloud at cloud.<domain> on servers. Files on the data volume (or in the state folder without
# one), app state with the host's state (the state volume, else the boot disk), database in the
# host's Postgres. Public through the tunnel so share links work without Tailscale; its own login
# guards it. Without a gateway on this host it stays on localhost. First account by hand after
# install, then two-factor in the web UI:
#   nextcloud-occ user:add <you> && nextcloud-occ group:adduser admin <you>
# With a login provider (axon.sso) the family logs in there too; the password form stays.
# Major versions upgrade one at a time: bump the package by one, switch, repeat.
# Kept only in its UI (database and app state, backed up): users, groups, shares.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        mail
        routed
        services
        sso
        ;
      inherit (services.cloud) route;
      client = sso.clients.nextcloud;
      data = config.axon.spaces.nextcloud.path;
      port = 8090;
    in
    lib.mkMerge [
      (lib.mkIf (config.axon.host.class == "server") {
        # at notice it logs each of its snapshots, every few minutes
        services.redis.servers.nextcloud.logLevel = "warning";

        services.nextcloud = {
          enable = true;
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
            # the module ties this to maxUploadSize, but uploads stream and one process needn't be
            # able to take all the memory
            memory_limit = lib.mkForce "1G";
          };
        };

        # nextcloud's nginx only on localhost; caddy owns 80/443
        services.nginx.virtualHosts.${route.name}.listen = [
          {
            addr = "127.0.0.1";
            inherit port;
          }
        ];

        axon.sso.clients.nextcloud = {
          displayName = "Nextcloud";
          landing = route.url;
          redirects = [ "${route.url}/apps/user_oidc/code" ];
          inherit (services.cloud.dashboard) icon;
        };

        axon.spaces.nextcloud = {
          user = "nextcloud";
          group = "nextcloud";
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
          "/var/lib/redis-nextcloud"
        ];

        axon.services.cloud = {
          space = "nextcloud";
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
            public = true;
          };
          dashboard = {
            name = "Nextcloud";
            group = "Files";
            description = "Files";
            icon = "nextcloud.svg";
            # / redirects to https on this plain http port
            monitor = "/status.php";
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
      })

      (lib.mkIf (config.axon.host.class == "server" && sso.provider != null) {
        services.nextcloud = {
          # this also closes the app store, which file storage alone doesn't need
          extraApps = { inherit (config.services.nextcloud.package.packages.apps) user_oidc; };
          # the provider answers on this host (127.0.0.1); Nextcloud refuses local addresses without it
          settings.allow_local_remote_servers = true;
        };

        # the provider as user_oidc stores it, updated on every setup run. The login is the short
        # name (preferred_username), as is, so it lands in the account of that name, made on the
        # first login where none exists; each login copies display name and mail address from the
        # provider, and Nextcloud's own second factor is asked only on the password form
        systemd.services.nextcloud-setup.script = lib.mkAfter ''
          nextcloud-occ user_oidc:provider Kanidm \
            --clientid=${client.id} \
            --clientsecret-file=${client.secret} \
            --discoveryuri=${client.issuer}/.well-known/openid-configuration \
            --mapping-uid=preferred_username \
            --unique-uid=0
        '';
      })

      # without an account Nextcloud runs the same, but invites and password resets fail
      (lib.mkIf (config.axon.host.class == "server" && mail != null) {
        sops.templates."nextcloud.json" = {
          owner = "nextcloud";
          content = lib.toJSON {
            mail_from_address = mail.user;
            mail_domain = mail.domain;
            mail_smtpname = mail.address;
            mail_smtppassword = mail.token;
          };
        };

        services.nextcloud = {
          settings = {
            mail_smtphost = mail.host;
            mail_smtpport = mail.port;
            mail_smtpauth = true;
          };
          secretFile = config.sops.templates."nextcloud.json".path;
        };
      })
    ];
}
