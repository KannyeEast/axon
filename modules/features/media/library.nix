# Watching and requesting: Jellyfin plays the library, Seerr takes requests and hands them
# to Radarr (movies) and Sonarr (shows). Both bring their own login and are public.
# Library layout on the bulk disks, shared through the media group:
#   /server/media/{movies,shows}   what Jellyfin shows
#   /server/media/downloads        finished downloads, same filesystem so imports are instant
{
  flake.modules.nixos.media =
    { ... }:
    let
      media = "/server/media";
    in
    {
      users.groups.media = { };

      systemd.tmpfiles.rules = map (dir: "d ${media}/${dir} 2775 root media -") [
        "movies"
        "shows"
        "downloads"
      ];

      services.jellyfin = {
        enable = true;
        group = "media";
      };
      services.seerr.enable = true;

      # the library is on a data disk that may be missing at boot (nofail)
      systemd.services.jellyfin.unitConfig.RequiresMountsFor = [ media ];

      axon.persist.directories = [
        {
          directory = "/var/lib/jellyfin";
          user = "jellyfin";
          group = "media";
          mode = "0750";
        }
        {
          directory = "/var/lib/private/seerr";
          mode = "0700";
        }
      ];

      axon.services = {
        jellyfin = {
          route = {
            port = 8096;
            access = "open";
            public = true;
          };
          dashboard = {
            name = "Jellyfin";
            group = "Media";
            description = "Movies and shows";
            icon = "jellyfin.svg";
            widget = {
              type = "jellyfin";
              version = 2;
              enableBlocks = true;
              enableNowPlaying = false;
            };
            secrets.key = "dashboard/jellyfin/key";
          };
          backup.paths = [ "/var/lib/jellyfin" ];
        };
        requests = {
          route = {
            port = 5055;
            access = "open";
            public = true;
          };
          dashboard = {
            name = "Seerr";
            group = "Media";
            description = "Requests";
            icon = "jellyseerr.svg";
            widget.type = "seerr";
            secrets.key = "dashboard/requests/key";
          };
          backup.paths = [ "/var/lib/private/seerr" ];
        };
      };
    };
}
