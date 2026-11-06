# Finding things: Prowlarr manages the indexers for Radarr (movies) and Sonarr (shows),
# Bazarr fetches subtitles. All behind the gateway login. They fill the movies/ and shows/ folders
# on the media volume, so they only run on a host that has one.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    let
      apps = {
        radarr = 7878;
        sonarr = 8989;
        bazarr = 6767;
      };
      prowlarr = 9696;
      inherit (config.axon) vpn;
      inherit (config.axon.volumes) media;

      # fields: four values make labels like "FAIL QUERIES" wrap, and the whole row grows with them
      fields = {
        prowlarr = [
          "numberOfGrabs"
          "numberOfQueries"
          "numberOfFailGrabs"
        ];
      };
      dashboard = app: description: {
        name = lib.toSentenceCase app;
        group = "Media";
        inherit description;
        icon = "${app}.svg";
        widget = {
          type = app;
        }
        // lib.optionalAttrs (fields ? ${app}) { fields = fields.${app}; };
        secrets.key = "dashboard/${app}/key";
      };
      descriptions = {
        radarr = "Movies";
        sonarr = "Shows";
        bazarr = "Subtitles";
      };
    in
    lib.mkIf (config.axon.volumes ? media) {
      services.radarr = {
        enable = true;
        group = "media";
      };
      services.sonarr = {
        enable = true;
        group = "media";
      };
      services.bazarr = {
        enable = true;
        group = "media";
      };
      services.prowlarr.enable = true;

      systemd.services = lib.genAttrs [ "radarr" "sonarr" "bazarr" ] (_: {
        unitConfig.RequiresMountsFor = [ media ];
        # what one app creates in the library, the others in the media group must be able to
        # write to: Bazarr puts subtitles into the folders Radarr and Sonarr make. Forced, as
        # their modules set 0022
        serviceConfig.UMask = lib.mkForce "0002";
      });

      systemd.tmpfiles.rules = map (dir: "d ${media}/${dir} 2775 root media -") [
        "movies"
        "shows"
      ];

      axon.vpn = {
        # Prowlarr talks to the trackers' sites, so it searches through the tunnel like
        # qBittorrent downloads; Radarr and Sonarr only talk to the two of them
        confined.prowlarr.ports = [ prowlarr ];
        # Prowlarr hands its indexers to Radarr and Sonarr on the host
        hostPorts = [
          apps.radarr
          apps.sonarr
        ];
      };

      # Radarr's module only declares .config/Radarr, so tmpfiles makes .config root's and then
      # refuses the unsafe step from radarr's folder into it: Radarr is never created
      systemd.tmpfiles.settings."10-radarr"."/var/lib/radarr/.config".d = {
        user = "radarr";
        group = "media";
        mode = "0750";
      };

      axon.persist.directories =
        map (app: {
          directory = "/var/lib/${app}";
          user = app;
          group = "media";
          mode = "0750";
        }) (builtins.attrNames apps)
        ++ [
          {
            directory = "/var/lib/private/prowlarr";
            mode = "0700";
          }
        ];

      axon.services =
        lib.mapAttrs (app: port: {
          route.port = port;
          dashboard = dashboard app descriptions.${app};
          backup.paths = [ "/var/lib/${app}" ];
        }) apps
        // {
          prowlarr = {
            route = {
              port = prowlarr;
              inherit (vpn) address;
            };
            dashboard = dashboard "prowlarr" "Indexers";
            backup.paths = [ "/var/lib/private/prowlarr" ];
          };
        };
    };
}
