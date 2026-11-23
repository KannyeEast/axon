# Radarr, Sonarr, Prowlarr and Bazarr at <name>.<domain>: movies, shows, indexers and subtitles.
# Reach: tailnet, the gateway's login; their own where the gateway has none.
# In their UIs only: download clients, root folders, Connect, indexers, subtitle sources; backed up.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon) hasSecret services;
      inherit (config.axon.volumes) media;
      # order: after Jellyfin, Seerr and the downloaders; attention: widget values amber above 0
      apps = {
        radarr = {
          port = 7878;
          order = 5;
          description = "Movies";
          # wanted: monitored, released and not there; missing also counts films still to come
          attention = [ "wanted" ];
        };
        sonarr = {
          port = 8989;
          order = 6;
          description = "Shows";
          attention = [ "wanted" ];
        };
        bazarr = {
          port = 6767;
          order = 8;
          description = "Subtitles";
          attention = [
            "missingEpisodes"
            "missingMovies"
          ];
        };
      };
      prowlarr = {
        port = 9696;
        order = 7;
        description = "Indexers";
        # four values make labels like "FAIL QUERIES" wrap, and the whole row grows with them
        fields = [
          "numberOfGrabs"
          "numberOfQueries"
          "numberOfFailGrabs"
        ];
      };

      # the first line of a log entry in the .NET apps; a stack trace follows it
      logStart = "^\\[(Trace|Debug|Info|Warn|Error|Fatal)\\]";

      # they insist on a login method: External behind the gateway's login, else Forms, off for
      # local addresses with the tailnet's 100.64.0.0/10 counted local (config.xml only, not the UI)
      settings = name: {
        server.allowedHosts =
          let
            inherit (config.axon.services.${name}) route;
          in
          lib.concatStringsSep "," [
            route.host
            route.address
          ];
        auth = {
          method = if services.${name}.route.gated then "External" else "Forms";
          required = "DisabledForLocalAddresses";
          trustCgnatIpAddresses = true;
        };
      };

      # without its key in secrets.json, an app keeps the one it made itself
      secret = name: services.${name}.apiKey;
      hasKey = name: hasSecret (secret name);
      keyed = lib.filter hasKey [
        "radarr"
        "sonarr"
        "prowlarr"
        "bazarr"
      ];
      # read over config.xml, as the settings above are
      envFile = name: lib.optional (hasKey name) config.sops.templates."${name}-key.env".path;

      dashboard = name: app: {
        name = lib.toSentenceCase name;
        group = "Media";
        inherit (app) description order;
        icon = "${name}.svg";
        widget = {
          type = name;
        }
        // lib.optionalAttrs (app ? fields) { inherit (app) fields; }
        // lib.optionalAttrs (app ? attention) {
          highlight = lib.genAttrs app.attention (_: {
            numeric = {
              level = "warn";
              when = "gt";
              value = 0;
            };
          });
        };
        key = true;
      };
    in
    lib.mkIf (config.axon.volumes ? media) {
      # ── service ────────
      services.radarr = {
        enable = true;
        group = "media";
        settings = settings "radarr";
        environmentFiles = envFile "radarr";
      };
      services.sonarr = {
        enable = true;
        group = "media";
        settings = settings "sonarr";
        environmentFiles = envFile "sonarr";
      };
      services.bazarr = {
        enable = true;
        group = "media";
        settings = lib.optionalAttrs (hasKey "bazarr") {
          auth.apikey._secret = config.sops.secrets.${secret "bazarr"}.path;
        };
      };
      services.prowlarr = {
        enable = true;
        settings = settings "prowlarr";
        environmentFiles = envFile "prowlarr";
      };

      # ── units ────────
      systemd.services = lib.mkMerge [
        (lib.genAttrs [ "radarr" "sonarr" "bazarr" ] (_: {
          unitConfig.RequiresMountsFor = [ media ];
          # Bazarr writes subtitles into the folders Radarr and Sonarr make, so what one creates
          # stays group-writable; forced over their modules' 0022
          serviceConfig.UMask = lib.mkForce "0002";
        }))
        # the library folders, made once the disk is mounted (tmpfiles may run before that)
        (lib.mapAttrs
          (_: dir: {
            serviceConfig.ExecStartPre = [
              "+${lib.getExe' pkgs.coreutils "install"} -d -o root -g media -m 2775 ${media}/${dir}"
            ];
          })
          {
            radarr = "movies";
            sonarr = "shows";
          }
        )
        # systemd sets it on every start, over the mode the folder was made with; Radarr has no
        # StateDirectory, and Bazarr's module makes its folder 0700 by tmpfiles
        { sonarr.serviceConfig.StateDirectoryMode = "0750"; }
      ];

      # Radarr's module only declares .config/Radarr, so tmpfiles makes .config root's and then
      # refuses the unsafe step from radarr's folder into it: Radarr is never created
      systemd.tmpfiles.rules = [ "d /var/lib/radarr/.config 0750 radarr media -" ];

      # ── secrets ────────
      sops.secrets = lib.listToAttrs (
        map (name: lib.nameValuePair (secret name) { restartUnits = [ "${name}.service" ]; }) keyed
      );
      sops.templates = lib.listToAttrs (
        map (
          name:
          lib.nameValuePair "${name}-key.env" {
            content = "${lib.toUpper name}__AUTH__APIKEY=${config.sops.placeholder.${secret name}}\n";
          }
        ) (lib.remove "bazarr" keyed)
      );

      # ── data ────────
      axon.persist.state.directories =
        map (
          app:
          {
            directory = "/var/lib/${app}";
            user = app;
            group = "media";
          }
          // lib.optionalAttrs (app != "bazarr") { mode = "0750"; }
        ) (lib.attrNames apps)
        ++ [ "/var/lib/private/prowlarr" ];

      # ── registration ────────
      axon.services =
        lib.mapAttrs (name: app: {
          units = [ name ];
          logStart = lib.mkIf (name != "bazarr") logStart;
          route.port = app.port;
          dashboard = dashboard name app;
          backup.paths = [ "/var/lib/${name}" ];
        }) apps
        // {
          prowlarr = {
            units = [ "prowlarr" ];
            inherit logStart;
            route.port = prowlarr.port;
            dashboard = dashboard "prowlarr" prowlarr;
            backup.paths = [ "/var/lib/private/prowlarr" ];
          };
        };
    };
}
