# Nextcloud at cloud.<domain> on servers; the sync client on desktops. Files on the data volume, or in the state folder on a host without one; database and app state on the system SSD.
# It's public (through the gateway's tunnel) so share links work for people without Tailscale;
# its own login guards it. The first account is created by hand after install:
#   nextcloud-occ user:add <you> && nextcloud-occ group:adduser admin <you>
# then turn on two-factor in the web UI.
# Major versions upgrade one at a time: bump the package by one, switch, repeat.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, pkgs, ... }:
    let
      inherit (config.axon) cluster mail;
      hostName = "cloud.${cluster.domain}";
      data = "${config.axon.volumes.data or "/var/lib"}/nextcloud";
      port = 8090;
    in
    lib.mkMerge [
      # the desktop half: the client that syncs Nextcloud folders to this machine
      (lib.mkIf (config.axon.host.class == "desktop") {
        environment.systemPackages = [ pkgs.nextcloud-client ];
      })

      (lib.mkIf (config.axon.host.class == "server") {
        services.nextcloud = {
          enable = true;
          package = pkgs.nextcloud35;
          inherit hostName;
          https = true;
          datadir = data;
          database.createLocally = true;
          configureRedis = true;
          maxUploadSize = "16G";
          config.dbtype = "pgsql";
          settings = {
            # the tunnel delivers plain http on localhost; links must still say https
            trusted_proxies = [
              "127.0.0.1"
              "::1"
            ];
            overwriteprotocol = "https";
            default_phone_region = "DE";
            serverid = 1; # unique per PHP server; there is one, but Nextcloud warns without it
            maintenance_window_start = 1; # 01:00 UTC
          };
          phpOptions."opcache.interned_strings_buffer" = "16";
        };

        # nextcloud's nginx only on localhost; caddy owns 80/443
        services.nginx.virtualHosts.${hostName}.listen = [
          {
            addr = "127.0.0.1";
            inherit port;
          }
        ];

        # the files live on a data disk that may be missing at boot (nofail): never write to root instead
        systemd.services.nextcloud-setup.unitConfig.RequiresMountsFor = [ data ];
        systemd.services.phpfpm-nextcloud.unitConfig.RequiresMountsFor = [ data ];

        # a nightly database dump, so a file-level backup of the dump is consistent
        services.postgresqlBackup = {
          enable = true;
          databases = [ "nextcloud" ];
        };

        axon.persist.directories = [
          {
            directory = "/var/lib/nextcloud";
            user = "nextcloud";
            group = "nextcloud";
            mode = "0750";
          }
          {
            directory = "/var/lib/postgresql";
            user = "postgres";
            group = "postgres";
            mode = "0750";
          }
          "/var/lib/redis-nextcloud"
          "/var/backup/postgresql"
        ];

        axon.services.cloud = {
          route = {
            inherit port;
            subdomain = "cloud";
            access = "open"; # Nextcloud's own login
            public = true;
          };
          dashboard = {
            name = "Nextcloud";
            group = "Files";
            description = "Files, calendar, contacts";
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
            secrets.key = "dashboard/cloud/key";
          };
          backup.paths = [
            data
            "/var/lib/nextcloud"
            "/var/backup/postgresql"
          ];
        };
      })

      # without an account Nextcloud runs the same, but invites and password resets fail
      (lib.mkIf (config.axon.host.class == "server" && mail != null) {
        sops.templates."nextcloud.json" = {
          owner = "nextcloud";
          content = builtins.toJSON {
            mail_from_address = mail.user;
            mail_domain = mail.domain;
            mail_smtpname = mail.address;
            mail_smtppassword = mail.token;
          };
        };

        services.nextcloud = {
          settings = {
            mail_smtpmode = "smtp";
            mail_smtphost = mail.host;
            mail_smtpport = mail.port;
            mail_smtpauth = true;
          };
          secretFile = config.sops.templates."nextcloud.json".path;
        };
      })
    ];
}
