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
      inherit (config.axon.services.requests) route;
      port = 5055;
      filter = 8098;
      # its module runs it as a DynamicUser, so its state lives under /var/lib/private
      state = "/var/lib/private/seerr";
      # the workflow reads both from n8n's environment, the filter Jellyfin's
      keys = {
        seerr = services.requests.apiKey;
        jellyfin = services.jellyfin.apiKey;
      };
      missing = lib.filter (secret: !hasSecret secret) (lib.attrValues keys);
      filtered = routes ? jellyfin && hasSecret keys.jellyfin;
    in
    lib.mkIf (config.axon.onDisk ? media) {
      # ── service ────────
      services.seerr = {
        enable = true;
        inherit port;
      };

      # ── units ────────
      systemd.services = {
        seerr = {
          environment = {
            HOST = "127.0.0.1";
            # its default is debug
            LOG_LEVEL = "info";
          };
          # the module waits for /var/lib/seerr, the link; the persisted folder is behind it
          unitConfig.RequiresMountsFor = [ state ];
          # systemd sets the mode on every start; settings.json holds API keys
          serviceConfig.StateDirectoryMode = "0700";
        };
        # Moonbase's Seerr URL; it hides titles from scoped users, which is not access control
        scope-filter = lib.mkIf filtered {
          description = "Seerr for Moonbase, without links to Jellyfin items the person can't see";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            DynamicUser = true;
            Restart = "on-failure";
            LoadCredential = "jellyfin:${config.sops.secrets.${keys.jellyfin}.path}";
            ExecStart = "${lib.getExe' pkgs.python3 "python3"} ${./_scope-filter.py} ${toString filter} ${route.internal} ${routes.jellyfin.route.internal}${
              lib.optionalString (routes ? automation) " ${routes.automation.route.internal}/webhook/scope-sync"
            }";
          };
        };
      };

      # ── secrets ────────
      sops.secrets = lib.mkIf filtered { ${keys.jellyfin} = { }; };

      # ── data ────────
      axon.persist.state.directories = [ state ];

      # ── registration ────────
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

      # ── checks ────────
      warnings = lib.mkIf (routes ? jellyfin) (
        lib.optional (missing != [ ])
          "hosts/${host.name}/secrets.json: no ${lib.concatStringsSep ", " missing}, so ${
            lib.optionalString (!filtered) "scope-filter and "
          }Scope tags don't run and Jellyfin users marked scoped see nothing; add them with `just secrets ${host.name}`"
        ++
          lib.optional (!routes ? automation)
            "hosts/${host.name}/host.toml: no automation on this host, so nothing sets scope tags and Jellyfin users marked scoped see nothing; list automation here to set them"
      );
    };
}
