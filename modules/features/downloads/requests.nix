# Seerr takes requests and hands them to Radarr (movies) and Sonarr (shows). It brings its own
# login and is tailnet only: the family requests from Moonfin, which reaches it through Moonbase on
# this host. Needs the library the arr stack fills, so it runs where that does. Kept only in its UI
# (settings.json, backed up): its links to Jellyfin, Radarr and Sonarr, users and override rules.
# A friend sees in Jellyfin only what they requested or put on their watchlist here: the owner adds
# the tag `friend` to that user's "Allow items with tags" in Jellyfin, and _friend-tags.py tags
# those titles for them. It runs on a call to 127.0.0.1:8097 (the filter below, on a request or
# watchlist change) and every 2 minutes for the rest (a title arriving in Jellyfin, stars in Seerr's
# web UI). It hides titles; it is not access control.
# Moonbase's Seerr URL is 127.0.0.1:8098, _friend-filter.py in front of Seerr: it drops the link to a
# Jellyfin item the person can't see (a movie becomes requestable), so Moonfin opens Seerr's page.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host routes;
      port = 5055;
      hook = 8097;
      filter = 8098;
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
          services.seerr = {
            enable = true;
            inherit port;
          };
          systemd.services.seerr = {
            environment = {
              HOST = "127.0.0.1";
              # its default is debug
              LOG_LEVEL = "info";
            };
            # a static user with a fixed id owns the state: as a DynamicUser, systemd would move
            # /var/lib/seerr into /var/lib/private, which fails on the persisted mount there
            serviceConfig = {
              DynamicUser = lib.mkForce false;
              User = "seerr";
              Group = "seerr";
              # systemd sets the mode on every start; settings.json holds API keys
              StateDirectoryMode = "0700";
            };
          };
          users.users.seerr = {
            isSystemUser = true;
            group = "seerr";
            uid = id;
          };
          users.groups.seerr.gid = id;

          axon.persist.state.directories = [
            {
              directory = state;
              user = "seerr";
              group = "seerr";
              mode = "0700";
            }
          ];

          axon.services.requests = {
            units = [
              "seerr"
            ]
            ++ lib.optionals (routes ? jellyfin && missing == [ ]) [
              "friend-filter"
              "friend-tags"
            ];
            route.port = port;
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
            "hosts/${host.name}/secrets.json: no ${lib.concatStringsSep ", " missing}, so friend-tags and friend-filter don't run and Jellyfin users marked friend see nothing; add them with `just secrets ${host.name}`"
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
          systemd.services.friend-filter = {
            description = "Seerr for Moonbase, without links to Jellyfin items the person can't see";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              DynamicUser = true;
              Restart = "on-failure";
              LoadCredential = "jellyfin:${config.sops.secrets.${keys.jellyfin}.path}";
              ExecStart = "${lib.getExe' pkgs.python3 "python3"} ${./_friend-filter.py} ${toString filter} ${routes.requests.route.internal} ${routes.jellyfin.route.internal} ${toString hook}";
            };
          };
        })
      ]
    );
}
