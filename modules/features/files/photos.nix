# Immich at photos.<domain> on servers: phone photo backup with face and place search.
# Originals on the data volume, or in the state folder on a host without one; database in the
# shared Postgres, machine learning on the CPU.
# Every account is its own library; sharing is through shared albums or partner sharing.
# The first account made in the web UI is the admin.
# Uploads through the tunnel are capped at 100 MB per file; tailnet devices skip the tunnel (the
# gateway's DNS sends them straight to it), so the cap only applies from outside.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, ... }:
    let
      data = config.axon.spaces.immich.path;
      port = 2283;
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

      axon.persist.directories = [
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
          secrets.key = "dashboard/photos/key";
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
