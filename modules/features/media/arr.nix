# Finding things: Prowlarr manages the indexers for Radarr (movies) and Sonarr (shows),
# Bazarr fetches subtitles. All behind the gateway login.
{ lib, ... }:
{
  flake.modules.nixos.media =
    { ... }:
    let
      apps = {
        radarr = 7878;
        sonarr = 8989;
        bazarr = 6767;
      };
    in
    {
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
        unitConfig.RequiresMountsFor = [ "/server/media" ];
      });

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
          backup.paths = [ "/var/lib/${app}" ];
        }) apps
        // {
          prowlarr = {
            route.port = 9696;
            backup.paths = [ "/var/lib/private/prowlarr" ];
          };
        };
    };
}
