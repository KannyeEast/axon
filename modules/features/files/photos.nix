# Immich at photos.<domain> on servers: phone photo backup with face and place search.
# Originals on the data volume (or in the state folder without one), database in the shared
# Postgres, machine learning on the CPU. Each account is its own library, shared through albums
# or partner sharing; the first one made in the web UI is the admin.
# Uploads through the tunnel are capped at 100 MB per file; the gateway's DNS sends tailnet
# devices past the tunnel, so the cap only applies from outside.
# Thumbnails and transcoded videos, which the timeline loads by the hundred, live in Immich's
# state on a host with a state volume, bind-mounted into the photo folder.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, ... }:
    let
      data = config.axon.spaces.immich.path;
      port = 2283;
      generated = lib.optionals (config.axon.volumes ? state && config.axon.spaces.immich.onVolume) [
        "thumbs"
        "encoded-video"
      ];
    in
    lib.mkIf (config.axon.host.class == "server") {
      services.immich = {
        enable = true;
        # "localhost" binds to ::1 only, and the gateway proxies to 127.0.0.1
        host = "127.0.0.1";
        inherit port;
        mediaLocation = data;
      };

      axon.spaces.immich = {
        user = "immich";
        group = "immich";
        units = [ "immich-server" ];
      };

      fileSystems = lib.listToAttrs (
        map (dir: {
          name = "${data}/${dir}";
          value = {
            device = "/var/lib/immich/${dir}";
            fsType = "none";
            options = [
              "bind"
              "nofail"
              "x-systemd.requires-mounts-for=/var/lib/immich"
              "x-systemd.requires=storage-immich.service"
              "x-systemd.after=storage-immich.service"
            ];
          };
        }) generated
      );
      systemd.tmpfiles.rules = map (dir: "d /var/lib/immich/${dir} 0750 immich immich -") generated;
      systemd.services.immich-server.unitConfig.RequiresMountsFor = map (dir: "${data}/${dir}") generated;

      axon.persist.state.directories = [
        {
          directory = "/var/lib/immich";
          user = "immich";
          group = "immich";
          mode = "0700";
        }
        # the machine-learning models, so they aren't downloaded again on every boot
        {
          directory = "/var/cache/immich";
          user = "immich";
          group = "immich";
          mode = "0700";
        }
        "/var/lib/redis-immich"
      ];

      axon.services.photos = {
        route = {
          inherit port;
          access = "open"; # Immich's own login
          public = true;
        };
        dashboard = {
          name = "Immich";
          group = "Files";
          description = "Photos and videos";
          icon = "immich.svg";
          widget = {
            type = "immich";
            version = 2;
          };
          key = true;
        };
        # thumbs/ and encoded-video/ are rebuilt from the originals; backups/ holds Immich's own database dumps
        backup.paths = map (dir: "${data}/${dir}") [
          "library"
          "upload"
          "profile"
          "backups"
        ];
      };
    };
}
