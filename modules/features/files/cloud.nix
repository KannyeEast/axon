# Nextcloud at cloud.<domain> on servers. Files on the data volume, or in the state folder on a
# host without one; app state on the system SSD, database in the shared Postgres.
# It's public (through the gateway's tunnel) so share links work for people without Tailscale;
# its own login guards it. Without a gateway on this host it stays on localhost.
# The first account is created by hand after install:
#   nextcloud-occ user:add <you> && nextcloud-occ group:adduser admin <you>
# then turn on two-factor in the web UI.
# Major versions upgrade one at a time: bump the package by one, switch, repeat.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, pkgs, ... }:
    let
      inherit (config.axon) mail routed services;
      inherit (services.cloud) route;
      data = config.axon.spaces.nextcloud.path;
      port = 8090;
    in
    lib.mkMerge [
      (lib.mkIf (config.axon.host.class == "server") {
        services.nextcloud = {
          enable = true;
          package = pkgs.nextcloud35;
          hostName = route.name;
          https = routed;
          datadir = data;
          database.createLocally = true;
          configureRedis = true;
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
          route = {
            inherit port;
            access = "open"; # Nextcloud's own login
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
