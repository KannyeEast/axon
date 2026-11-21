# Finding things: Prowlarr manages the indexers for Radarr (movies) and Sonarr (shows),
# Bazarr fetches subtitles. All tailnet-only, behind the gateway's login where it runs. They fill
# the movies/ and shows/ folders on the media volume, so they only run on a host that has one.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon) vpn;
      inherit (config.axon.volumes) media;
      # order: Jellyfin and Seerr first, then the downloaders, then these four (Media fills rows
      # left to right). attention: widget values marked amber above 0
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

      # they insist on a login method: External where the gateway's login stands in front, else
      # Forms, off for local addresses with the tailnet's 100.64.0.0/10 counted as local (a
      # setting config.xml has and the UI doesn't). Settings here win over config.xml
      settings = name: {
        # names they answer to besides loopback: their route and their own address (Prowlarr's in
        # the VPN namespace)
        server.allowedHosts =
          let
            inherit (config.axon.services.${name}) route;
          in
          lib.concatStringsSep "," [
            route.host
            (lib.head (lib.splitString ":" (lib.removePrefix "http://" route.internal)))
          ];
        auth = {
          method =
            if config.axon.services.${name}.route.gate && config.services.oauth2-proxy.enable then
              "External"
            else
              "Forms";
          required = "DisabledForLocalAddresses";
          trustCgnatIpAddresses = true;
        };
      };

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
      services.radarr = {
        enable = true;
        group = "media";
        settings = settings "radarr";
      };
      services.sonarr = {
        enable = true;
        group = "media";
        settings = settings "sonarr";
      };
      services.bazarr = {
        enable = true;
        group = "media";
      };
      services.prowlarr = {
        enable = true;
        settings = settings "prowlarr";
      };

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
      ];

      axon.vpn = {
        # Prowlarr talks to the trackers' sites, so it searches through the tunnel like
        # qBittorrent downloads; Radarr and Sonarr only talk to the two of them
        confined.prowlarr.ports = [ prowlarr.port ];
        # Prowlarr hands its indexers to Radarr and Sonarr on the host
        hostPorts = [
          apps.radarr.port
          apps.sonarr.port
        ];
      };

      # Radarr's module only declares .config/Radarr, so tmpfiles makes .config root's and then
      # refuses the unsafe step from radarr's folder into it: Radarr is never created
      systemd.tmpfiles.rules = [ "d /var/lib/radarr/.config 0750 radarr media -" ];

      axon.persist.state.directories =
        map (app: {
          directory = "/var/lib/${app}";
          user = app;
          group = "media";
          mode = "0750";
        }) (lib.attrNames apps)
        ++ [
          {
            directory = "/var/lib/private/prowlarr";
            mode = "0700";
          }
        ];

      axon.services =
        lib.mapAttrs (name: app: {
          units = [ name ];
          route.port = app.port;
          dashboard = dashboard name app;
          backup.paths = [ "/var/lib/${name}" ];
        }) apps
        // {
          prowlarr = {
            units = [ "prowlarr" ];
            route = {
              inherit (prowlarr) port;
              inherit (vpn.network) address;
            };
            dashboard = dashboard "prowlarr" prowlarr;
            backup.paths = [ "/var/lib/private/prowlarr" ];
          };
        };
    };
}
