# Jellyfin plays what's on the media volume, shared through the media group. It brings its own
# login and is public.
{ lib, ... }:
{
  flake.modules.nixos.media =
    { config, ... }:
    let
      inherit (config.axon) host volumes;
      media = volumes.media;
    in
    lib.mkIf (host.class == "server") {
      assertions = [
        {
          assertion = volumes ? media;
          message = "hosts/${host.name}/host.toml: the media feature needs a volume called media; add it to the mounts of a [disk.<label>] table";
        }
      ];

      users.groups.media = { };

      services.jellyfin = {
        enable = true;
        group = "media";
      };

      # the library is on a data disk that may be missing at boot (nofail)
      systemd.services.jellyfin.unitConfig.RequiresMountsFor = [ media ];

      axon.persist.state.directories = [
        {
          directory = "/var/lib/jellyfin";
          user = "jellyfin";
          group = "media";
          mode = "0750";
        }
      ];

      axon.services.jellyfin = {
        route = {
          port = 8096;
          access = "open";
          public = true;
        };
        dashboard = {
          name = "Jellyfin";
          order = 5;
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
    };
}
