# SABnzbd: downloads from Usenet, outside the VPN (the provider connection is SSL, and nobody
# else sees it). Unfinished downloads on the scratch volume, finished ones next to the torrents
# on the media volume, by category (movies, tv) so Radarr and Sonarr import them; on a host
# without those volumes, in its state folder. Provider, connections and the API key are set in its
# UI and kept; what is declared here wins on every start.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    let
      inherit (config.axon) routed services volumes;
      state = "/var/lib/sabnzbd";
      finished = "${volumes.media or state}/downloads";
      incomplete = "${volumes.scratch or state}/usenet";
      port = 8080;
    in
    {
      users.groups.media = { };

      services.sabnzbd = {
        enable = true;
        group = "media";
        allowConfigWrite = true;
        settings = {
          misc = {
            host = "127.0.0.1";
            inherit port;
            # the gateway login guards the UI; SABnzbd itself only checks the name it's reached by
            host_whitelist = lib.optionalString routed services.usenet.route.host;
            download_dir = incomplete;
            complete_dir = finished;
            # Radarr and Sonarr, in the media group, move and delete what lands here
            permissions = "775";
          };
          categories = {
            movies = {
              name = "movies";
              dir = "movies";
            };
            tv = {
              name = "tv";
              dir = "tv";
            };
          };
        };
      };

      # the library is on a data disk that may be missing at boot (nofail)
      systemd.services.sabnzbd.unitConfig.RequiresMountsFor =
        lib.optional (volumes ? media) volumes.media ++ lib.optional (volumes ? scratch) volumes.scratch;

      systemd.tmpfiles.rules =
        lib.optional (volumes ? media) "d ${finished} 2775 root media -"
        ++ lib.optional (volumes ? scratch) "d ${incomplete} 2775 root media -";

      axon.persist.directories = [
        {
          directory = state;
          user = "sabnzbd";
          group = "media";
          mode = "0750";
        }
      ];

      axon.services.usenet = {
        route = { inherit port; };
        dashboard = {
          name = "SABnzbd";
          group = "Media";
          description = "Downloads from Usenet";
          icon = "sabnzbd.svg";
          widget.type = "sabnzbd";
          secrets.key = "dashboard/usenet/key";
        };
        backup = {
          paths = [ state ];
          exclude = lib.optional (!volumes ? media) finished ++ lib.optional (!volumes ? scratch) incomplete;
        };
      };
    };
}
