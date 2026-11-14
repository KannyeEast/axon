# Seerr takes requests and hands them to Radarr (movies) and Sonarr (shows). It brings its own
# login and is public. Needs the library the arr stack fills, so it runs where that does.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    let
      port = 5055;
      state = "/var/lib/seerr";
      id = 400;
    in
    lib.mkIf (config.axon.volumes ? media) {
      users.users.seerr = {
        isSystemUser = true;
        group = "seerr";
        uid = id;
      };
      users.groups.seerr.gid = id;

      virtualisation.oci-containers.containers.seerr = {
        image = "ghcr.io/seerr-team/seerr:v3.5.2@sha256:aadee014b40e28cf9aa4928bc9d1183a6eb08f8c44d543cddc9efdcb16549be2";
        user = "${toString id}:${toString id}";
        # reaches Jellyfin, Radarr and Sonarr on 127.0.0.1
        networks = [ "host" ];
        # node directly: npm wants a writable home, which this user hasn't
        cmd = [
          "node"
          "dist/index.js"
        ];
        environment = {
          HOST = "127.0.0.1";
          PORT = toString port;
          TZ = config.axon.locale.timezone;
        };
        volumes = [ "${state}:/app/config" ];
      };

      axon.persist.state.directories = [
        {
          directory = state;
          user = "seerr";
          group = "seerr";
          mode = "0700";
        }
      ];

      axon.services.requests = {
        route = {
          inherit port;
          public = true;
        };
        dashboard = {
          name = "Seerr";
          order = 1;
          group = "Media";
          description = "Requests";
          icon = "jellyseerr.svg";
          widget.type = "seerr";
          key = true;
        };
        backup.paths = [ state ];
      };
    };
}
