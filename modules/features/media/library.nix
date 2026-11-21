# Jellyfin plays what's on the media volume, shared through the media group; without one it starts
# with no library on disk. It brings its own login and is public.
{ lib, ... }:
{
  flake.modules.nixos.media =
    { config, ... }:
    let
      inherit (config.axon) host volumes;
    in
    lib.mkIf (host.class == "server") {
      users.groups.media = { };

      services.jellyfin = {
        enable = true;
        group = "media";
      };

      # the library is on a data disk that may be missing at boot (nofail)
      systemd.services.jellyfin.unitConfig.RequiresMountsFor = lib.optional (
        volumes ? media
      ) volumes.media;

      axon.persist.state.directories =
        map
          (directory: {
            inherit directory;
            user = "jellyfin";
            group = "media";
            mode = "0700";
          })
          [
            "/var/lib/jellyfin"
            # image cache and transcodes; rebuilt after every boot otherwise
            config.services.jellyfin.cacheDir
          ];

      axon.services.jellyfin = {
        space = "media";
        units = [ "jellyfin" ];
        route = {
          port = 8096;
          public = true;
        };
        dashboard = {
          name = "Jellyfin";
          order = 1;
          group = "Media";
          description = "Movies and shows";
          icon = "jellyfin.svg";
          widget = {
            type = "jellyfin";
            version = 2;
            enableBlocks = true;
            enableNowPlaying = false;
          };
          key = true;
        };
        backup.paths = [ "/var/lib/jellyfin" ];
      };
    };
}
