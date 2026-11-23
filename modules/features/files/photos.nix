# Immich at photos.<domain>: phone photo backup with face and place search.
# Reach: public, its own login and axon.sso's (matched by mail address) where there is one.
# In its UI only: accounts, albums and sharing, in its database, backed up; settings come from here.
# By hand: the first account made in the web UI is the admin.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, ... }:
    let
      inherit (config.axon) domain mail sso;
      inherit (config.axon.services.photos) route;
      port = 2283;
      client = sso.clients.immich;
      data = config.axon.spaces.immich.path;
      generated = lib.optionals (config.axon.volumes ? state && config.axon.spaces.immich.onVolume) [
        "thumbs"
        "encoded-video"
      ];
    in
    lib.mkIf (config.axon.host.class == "server") {
      # ── service ────────
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
            from = "Immich <photos@${domain}>";
            transport = {
              inherit (mail) host port;
              username._secret = config.sops.templates."immich-mail-login".path;
              password._secret = config.sops.templates."immich-mail-token".path;
            };
          };
        };
      };

      # at notice it logs each of its snapshots, every few minutes
      services.redis.servers.immich.logLevel = "warning";

      # ── units ────────
      systemd.services.immich-server.unitConfig.RequiresMountsFor = map (dir: "${data}/${dir}") generated;
      # systemd sets these on every start, over the mode the folders were made with
      systemd.services.immich-server.serviceConfig.StateDirectoryMode = "0700";
      systemd.services.immich-machine-learning.serviceConfig.CacheDirectoryMode = "0700";

      # ── secrets ────────
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

      # ── login ────────
      axon.sso.clients.immich = {
        service = "photos";
        redirects = [
          "${route.url}/auth/login"
          "${route.url}/user-settings"
          "app.immich:///oauth-callback"
        ];
      };

      # ── data ────────
      # thumbnails and videos the timeline loads by the hundred stay on the state volume
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
      axon.spaces.immich = {
        user = "immich";
        group = "immich";
        units = [ "immich-server" ];
      };

      axon.databases = [ "immich" ];

      # the models persist, so they aren't downloaded on every boot; the generated folders get their
      # own entries, as a tmpfiles rule inside /var/lib/immich runs before its mount and is hidden
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

      # ── registration ────────
      axon.services.photos = {
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
          space = "immich";
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
