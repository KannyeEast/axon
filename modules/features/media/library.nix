# Watching and requesting: Jellyfin plays the library, Seerr takes requests and hands them
# to Radarr (movies) and Sonarr (shows). Both have their own logins; the tailnet is the fence.
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
          };
          backup.paths = [ "/var/lib/jellyfin" ];
        };
        requests = {
          route = {
            port = 5055;
            access = "open";
          };
          backup.paths = [ "/var/lib/private/seerr" ];
        };
      };
    };
}
