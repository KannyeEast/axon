# Seerr at requests.<domain>: requests, handed to Radarr (movies) and Sonarr (shows).
# Reach: tailnet, the gateway's login and Seerr's own.
# In its UI only: its links to the arr apps and Jellyfin, users, rules and mail; backed up.
# By hand: its mail settings (axon.mail's login); a scoped user's Jellyfin tag `scoped`; Moonbase's Seerr URL http://127.0.0.1:8098 in Jellyfin.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        hasSecret
        host
        routes
        services
        ;
      port = 5055;
      filter = 8098;
      state = "/var/lib/seerr";
      id = 400;
      # the workflow reads both from n8n's environment, the filter Jellyfin's
      keys = {
        seerr = services.requests.apiKey;
        jellyfin = services.jellyfin.apiKey;
      };
      missing = lib.filter (secret: !hasSecret secret) (lib.attrValues keys);
      filtered = routes ? jellyfin && hasSecret keys.jellyfin;
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

          # Moonbase's Seerr URL; it hides titles from scoped users, which is not access control
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
