# Yuvomi at plan.<domain>, tailnet only: the family's calendar, tasks, shopping lists and meal
# plans. One container on the host's network, listening on 127.0.0.1. Its SQLite database is
# encrypted with yuvomi/db-encryption-key, which can never change: lost, the data and every
# backup are lost with it. Its own nightly copy (02:00, the last seven kept) is what gets backed
# up. The first account, made in the browser on the first visit, is the admin. With a login provider
# (axon.sso) the family logs in there too: a first login makes a member account; an admin's is
# linked by its verified mail address or from its own settings.
{ lib, ... }:
{
  flake.modules.nixos.family =
    { config, ... }:
    let
      inherit (config.axon) sso;
      inherit (config.axon.services.plan) route;
      client = sso.clients.yuvomi;
      ph = config.sops.placeholder;
      port = 3010;
      state = "/var/lib/yuvomi";
      id = 401;
      callback = "${route.url}/api/v1/auth/oidc/callback";
      secrets = {
        SESSION_SECRET = ph."yuvomi/session-secret";
        DB_ENCRYPTION_KEY = ph."yuvomi/db-encryption-key";
      }
      // lib.optionalAttrs (sso.provider != null) { OIDC_CLIENT_SECRET = ph."sso/${client.id}"; };
    in
    {
      users.users.yuvomi = {
        isSystemUser = true;
        group = "yuvomi";
        uid = id;
      };
      users.groups.yuvomi.gid = id;

      virtualisation.oci-containers.containers.yuvomi = {
        image = "ghcr.io/ulsklyc/yuvomi:2.90.0@sha256:3538e3d464038695cd86cfb1d7c63f60b343b462f1a77bfa00a93507c9694b86";
        # started as this user, the entrypoint skips its chown and runs node directly
        user = "${toString id}:${toString id}";
        # reaches Kanidm through the gateway on this host
        networks = [ "host" ];
        environment = {
          NODE_ENV = "production";
          BIND_ADDRESS = "127.0.0.1";
          PORT = toString port;
          BASE_URL = route.origin;
          # cookies only over HTTPS, which the gateway provides
          SESSION_SECURE = lib.boolToString config.axon.routed;
          TZ = config.axon.locale.timezone;
        }
        // lib.optionalAttrs (sso.provider != null) {
          OIDC_ISSUER = client.issuer;
          OIDC_CLIENT_ID = client.id;
          OIDC_REDIRECT_URI = callback;
        };
        environmentFiles = [ config.sops.templates."yuvomi.env".path ];
        volumes = [
          "${state}/data:/data"
          "${state}/backups:/backups"
        ];
      };

      sops.secrets."yuvomi/session-secret" = { };
      sops.secrets."yuvomi/db-encryption-key" = { };
      sops.templates."yuvomi.env" = {
        # Docker's --env-file takes every value verbatim, quotes included
        content = lib.concatStrings (lib.mapAttrsToList (key: value: "${key}=${value}\n") secrets);
        restartUnits = [ "docker-yuvomi.service" ];
      };

      axon.sso.clients.yuvomi = {
        displayName = "Yuvomi";
        landing = route.url;
        redirects = [ callback ];
      };

      # each folder persisted on its own, so the persist step makes it with its owner before the
      # container starts; Docker would make a missing one as root, which uid 401 can't write
      axon.persist.state.directories =
        map
          (dir: {
            directory = "${state}/${dir}";
            user = "yuvomi";
            group = "yuvomi";
            mode = "0700";
          })
          [
            "data"
            "backups"
          ];

      axon.services.plan = {
        route.port = port;
        dashboard = {
          name = "Yuvomi";
          group = "Files";
          description = "Family planner";
          icon = "yuvomi.svg";
        };
        backup.paths = [ "${state}/backups" ];
      };
    };
}
