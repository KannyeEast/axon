# Seerr takes requests and hands them to Radarr (movies) and Sonarr (shows). It brings its own
# login and is public. Needs the library the arr stack fills, so it runs where that does.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    lib.mkIf (config.axon.volumes ? media) {
      services.seerr.enable = true;

      axon.persist.state.directories = [
        {
          directory = "/var/lib/private/seerr";
          mode = "0700";
        }
      ];

      axon.services.requests = {
        route = {
          port = 5055;
          access = "open";
          public = true;
        };
        dashboard = {
          name = "Seerr";
          order = 1;
          group = "Media";
          description = "Requests";
          icon = "jellyseerr.svg";
          widget.type = "seerr";
          secrets.key = "dashboard/requests/key";
        };
        backup.paths = [ "/var/lib/private/seerr" ];
      };
    };
}
