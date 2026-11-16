# Seerr takes requests and hands them to Radarr (movies) and Sonarr (shows). It brings its own
# login and is public. Needs the library the arr stack fills, so it runs where that does.
# A friend sees in Jellyfin only what they requested or put on their watchlist here: the owner adds
# the tag `friend` to that user's "Allow items with tags" in Jellyfin, and _friend-tags.py tags
# those titles for them: on a call to 127.0.0.1:8097 (Jellyfin's Webhook plugin, Item Added) and
# every 2 minutes for watchlist stars, which call nothing. It hides titles; it is not access control.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host routes;
      port = 5055;
      hook = 8097;
      state = "/var/lib/seerr";
      id = 400;
      keys = {
        seerr = "dashboard/requests/key";
        jellyfin = "dashboard/jellyfin/key";
      };
      hasKey = secret: lib.hasAttrByPath (lib.splitString "/" secret) config.axon.secrets;
      missing = lib.filter (secret: !hasKey secret) (lib.attrValues keys);
    in
    lib.mkIf (config.axon.volumes ? media) (
      lib.mkMerge [
        {
          users.users.seerr = {
            isSystemUser = true;
            group = "seerr";
            uid = id;
          };
          users.groups.seerr.gid = id;

          virtualisation.oci-containers.containers.seerr = {
            image = "ghcr.io/seerr-team/seerr:v3.5.2@sha256:aadee014b40e28cf9aa4928bc9d1183a6eb08f8c44d543cddc9efdcb16549be2";
            user = "${toString id}:${toString id}";
            # reaches Jellyfin, Radarr and Sonarr on 127.0.0.1
            networks = [ "host" ];
            # node directly: npm wants a writable home, which this user hasn't
            cmd = [
              "node"
              "dist/index.js"
            ];
            environment = {
              HOST = "127.0.0.1";
              PORT = toString port;
              TZ = config.axon.locale.timezone;
            };
            volumes = [ "${state}:/app/config" ];
          };

          axon.persist.state.directories = [
            {
              directory = state;
              user = "seerr";
              group = "seerr";
              mode = "0700";
            }
          ];

          axon.services.requests = {
            route = {
              inherit port;
              public = true;
            };
            dashboard = {
              name = "Seerr";
              order = 2;
              group = "Media";
              description = "Requests";
              icon = "jellyseerr.svg";
              widget.type = "seerr";
              key = true;
            };
            backup.paths = [ state ];
          };
        }

        (lib.mkIf (routes ? jellyfin && missing != [ ]) {
          warnings = [
            "hosts/${host.name}/secrets.json: no ${lib.concatStringsSep ", " missing}, so friend-tags doesn't run and Jellyfin users marked friend see nothing; add them with `just secrets ${host.name}`"
          ];
        })

        (lib.mkIf (routes ? jellyfin && missing == [ ]) {
          sops.secrets = lib.genAttrs (lib.attrValues keys) (_: { });

          systemd.services.friend-tags = {
            description = "Tag what friends asked for in Seerr, for Jellyfin";
            serviceConfig = {
              Type = "oneshot";
              DynamicUser = true;
              LoadCredential = lib.mapAttrsToList (
                name: secret: "${name}:${config.sops.secrets.${secret}.path}"
              ) keys;
              ExecStart = "${lib.getExe' pkgs.python3 "python3"} ${./_friend-tags.py} ${routes.requests.route.internal} ${routes.jellyfin.route.internal}";
            };
          };
          # a call here starts friend-tags.service, which answers it before it syncs
          systemd.sockets.friend-tags = {
            wantedBy = [ "sockets.target" ];
            listenStreams = [ "127.0.0.1:${toString hook}" ];
          };
          systemd.timers.friend-tags = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              # a switch that adds the timer runs it at once: boot plus 5m is past by then
              OnBootSec = "5m";
              OnUnitActiveSec = "2m";
            };
          };
        })
      ]
    );
}
