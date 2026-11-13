# Trailarr: downloads trailers for what Radarr and Sonarr hold into the library folders, where
# Jellyfin plays them as local extras. A container, as nixpkgs has no package. Behind the gateway
# login, on a host with a media volume.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    let
      inherit (config.axon.volumes) media;
      state = "/var/lib/trailarr";
      port = 7889;
      library = map (dir: "${media}/${dir}:${media}/${dir}") [
        "movies"
        "shows"
      ];
    in
    lib.mkIf (config.axon.volumes ? media) {
      # rootful: the entrypoint needs root to switch to PUID/PGID, which own the library's files
      virtualisation.oci-containers.containers.trailarr = {
        image = "docker.io/nandyalu/trailarr:0.14.2@sha256:743414042dff1496a73808fc8f86c00bfb2d4ba88245b8d69e6d2ee9c0476094";
        # reaches Radarr and Sonarr on 127.0.0.1; listens on all addresses, the firewall keeps the
        # port closed
        networks = [ "host" ];
        # a subfolder: the entrypoint makes /config world-readable at every start, and the
        # database holds the Radarr and Sonarr API keys; the 0750 parent keeps others out
        volumes = [ "${state}/config:/config" ] ++ library;
        environment = {
          TZ = config.axon.locale.timezone;
          PUID = toString config.users.users.radarr.uid;
          PGID = toString config.users.groups.media.gid;
          WEBUI_DISABLE_AUTH = "true"; # the gateway login guards it
          UPDATE_YTDLP = "true"; # YouTube breaks a pinned yt-dlp within weeks
        };
        # group-writable for the *arr apps where Trailarr copies instead of moving, or makes parents
        extraOptions = [ "--umask=0002" ];
      };

      # fixed, as the container gets it as a number
      users.groups.media.gid = 996;

      # old image versions stay tagged, so plain pruning keeps them
      virtualisation.podman.autoPrune = {
        enable = true;
        flags = [ "--all" ];
      };

      systemd.services.podman-trailarr.unitConfig.RequiresMountsFor = [ media ];
      systemd.tmpfiles.rules = map (dir: "d ${dir} 0750 radarr media -") [
        state
        "${state}/config"
      ];

      axon.persist.state.directories = [
        {
          directory = state;
          user = "radarr";
          group = "media";
          mode = "0750";
        }
        # the pulled image; without it every boot downloads it again
        "/var/lib/containers"
      ];

      axon.services.trailers = {
        route = { inherit port; };
        dashboard = {
          name = "Trailarr";
          group = "Media";
          order = 9;
          description = "Trailers";
          icon = "trailarr.svg";
          monitor = "/status";
        };
        backup = {
          paths = [ state ];
          # posters and fanart it fetches again
          exclude = [ "${state}/config/web/images" ];
        };
      };
    };
}
