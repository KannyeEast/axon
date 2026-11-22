# Immich at photos.<domain> on servers: phone photo backup with face and place search. Originals
# on the data volume (or in the state folder without one), database in the host's Postgres,
# machine learning on the CPU. Each account is its own library, shared through albums or partner
# sharing; the first one made in the web UI is the admin. Settings come from here, read-only in
# the UI. With a login provider (axon.sso) the family logs in there, matched by mail address.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, ... }:
    let
      inherit (config.axon) mail sso;
      inherit (config.axon.services.photos) route;
      client = sso.clients.immich;
      data = config.axon.spaces.immich.path;
      port = 2283;
      generated = lib.optionals (config.axon.volumes ? state && config.axon.spaces.immich.onVolume) [
        "thumbs"
        "encoded-video"
      ];
    in
    lib.mkIf (config.axon.host.class == "server") {
      # at notice it logs each of its snapshots, every few minutes
      services.redis.servers.immich.logLevel = "warning";

      services.immich = {
        enable = true;
        # "localhost" binds to ::1 only, and the gateway proxies to 127.0.0.1
        host = "127.0.0.1";
        inherit port;
        mediaLocation = data;
        settings = {
          server.externalDomain = route.origin;
          # its database is dumped with the host's others (axon.databases)
          backup.database.enabled = false;
          storageTemplate = {
            enabled = true;
            template = "{{y}}/{{MM}}/{{dd}}/{{filename}}";
          };
          oauth = lib.mkIf (sso.provider != null) {
            enabled = true;
            issuerUrl = client.issuer;
            clientId = client.id;
            clientSecret._secret = client.secret;
            # Kanidm signs ID tokens with ES256
            signingAlgorithm = "ES256";
            buttonText = "Login with Kanidm";
          };
          # shared albums and password resets by mail; without an account it sends none
          notifications.smtp = lib.mkIf (mail != null) {
            enabled = true;
            from = "Immich <photos@${mail.domain}>";
            transport = {
              inherit (mail) host port;
              username._secret = config.sops.templates."immich-mail-login".path;
              password._secret = config.sops.templates."immich-mail-token".path;
            };
          };
        };
      };

      # the login and token are sops placeholders, so they reach Immich's settings as files
      sops.templates = lib.mkIf (mail != null) (
        lib.mapAttrs
          (_: content: {
            inherit content;
            owner = "immich";
            restartUnits = [ "immich-server.service" ];
          })
          {
            "immich-mail-login" = mail.login;
            "immich-mail-token" = mail.token;
          }
      );

      axon.sso.clients.immich = {
        displayName = "Immich";
        landing = route.url;
        redirects = [
          "${route.url}/auth/login"
          "${route.url}/user-settings"
          "app.immich:///oauth-callback"
        ];
        inherit (config.axon.services.photos.dashboard) icon;
      };

      axon.spaces.immich = {
        user = "immich";
        group = "immich";
        units = [ "immich-server" ];
      };

      # thumbnails and transcoded videos, which the timeline loads by the hundred,
      # stay on the state volume
      fileSystems = lib.listToAttrs (
        map (dir: {
          name = "${data}/${dir}";
          value = {
            device = "/var/lib/immich/${dir}";
            fsType = "none";
            options = [
              "bind"
              "nofail"
              "x-systemd.requires-mounts-for=/var/lib/immich/${dir}"
              "x-systemd.requires=storage-immich.service"
              "x-systemd.after=storage-immich.service"
            ];
          };
        }) generated
      );
      systemd.services.immich-server.unitConfig.RequiresMountsFor = map (dir: "${data}/${dir}") generated;

      axon.databases = [ "immich" ];

      # the models in /var/cache/immich, so they aren't downloaded on every boot; the generated
      # folders as entries of their own, as a tmpfiles rule inside /var/lib/immich runs before its
      # mount on a switch and ends up hidden under it
      axon.persist.state.directories =
        map
          (directory: {
            inherit directory;
            user = "immich";
            group = "immich";
            mode = "0700";
          })
          (
            [
              "/var/lib/immich"
              "/var/cache/immich"
            ]
            ++ map (dir: "/var/lib/immich/${dir}") generated
          )
        ++ [ "/var/lib/redis-immich" ];

      axon.services.photos = {
        space = "immich";
        units = [
          "immich-machine-learning"
          "immich-server"
          "redis-immich"
        ];
        route = {
          inherit port;
          public = true;
        };
        dashboard = {
          name = "Immich";
          group = "Files";
          description = "Photos and videos";
          icon = "immich.svg";
          widget = {
            type = "immich";
            version = 2;
          };
          key = true;
        };
        # thumbs/ and encoded-video/ are rebuilt from the originals
        backup.paths = map (dir: "${data}/${dir}") [
          "library"
          "upload"
          "profile"
        ];
      };
    };
}
