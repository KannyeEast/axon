# Seerr takes requests and hands them to Radarr (movies) and Sonarr (shows). It brings its own
# login and is tailnet only: the family requests from Moonfin, which reaches it through Moonbase on
# this host. Needs the library the arr stack fills, so it runs where that does. Kept only in its UI
# (settings.json, backed up): its links to Jellyfin, Radarr and Sonarr, users, override rules and
# mail notifications (axon.mail's login, sent from requests@ the cluster domain, entered by hand).
# A scoped user sees in Jellyfin only what they requested or put on their watchlist here: the owner
# adds the tag `scoped` to that user's "Allow items with tags" in Jellyfin, and the n8n workflow
# "Scope tags" (automation) tags those titles for them. It hides titles; it is not access control.
# Moonbase's Seerr URL is 127.0.0.1:8098, _scope-filter.py in front of Seerr: it drops the link to a
# Jellyfin item the person can't see (a movie becomes requestable), so Moonfin opens Seerr's page,
# and calls the workflow on a request or watchlist change.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host routes;
      port = 5055;
      filter = 8098;
      state = "/var/lib/seerr";
      id = 400;
      # the workflow reads both from n8n's environment, the filter Jellyfin's
      keys = {
        seerr = "dashboard/requests/key";
        jellyfin = "dashboard/jellyfin/key";
      };
      hasKey = secret: lib.hasAttrByPath (lib.splitString "/" secret) config.axon.secrets;
      missing = lib.filter (secret: !hasKey secret) (lib.attrValues keys);
      filtered = routes ? jellyfin && hasKey keys.jellyfin;
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
            ++ lib.optional filtered "scope-filter";
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

        (lib.mkIf (routes ? jellyfin) {
          warnings =
            lib.optional (missing != [ ])
              "hosts/${host.name}/secrets.json: no ${lib.concatStringsSep ", " missing}, so ${
                lib.optionalString (!filtered) "scope-filter and "
              }Scope tags don't run and Jellyfin users marked scoped see nothing; add them with `just secrets ${host.name}`"
            ++
              lib.optional (!routes ? automation)
                "hosts/${host.name}/host.toml: no automation on this host, so nothing sets scope tags and Jellyfin users marked scoped see nothing; list automation here to set them";
        })

        (lib.mkIf filtered {
          sops.secrets.${keys.jellyfin} = { };

          systemd.services.scope-filter = {
            description = "Seerr for Moonbase, without links to Jellyfin items the person can't see";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              DynamicUser = true;
              Restart = "on-failure";
              LoadCredential = "jellyfin:${config.sops.secrets.${keys.jellyfin}.path}";
              ExecStart = "${lib.getExe' pkgs.python3 "python3"} ${./_scope-filter.py} ${toString filter} ${routes.requests.route.internal} ${routes.jellyfin.route.internal}${
                lib.optionalString (routes ? automation) " ${routes.automation.route.internal}/webhook/scope-sync"
              }";
            };
          };
        })
      ]
    );
}
