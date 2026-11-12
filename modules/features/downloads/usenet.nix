# SABnzbd: downloads from Usenet, outside the VPN (the provider connection is SSL, and nobody
# else sees it). Unfinished downloads on the scratch volume, finished ones next to the torrents
# on the media volume, by category (movies, tv) so Radarr and Sonarr import them; on a host
# without those volumes, in its state folder. Provider, connections and the API key are set in its
# UI and kept; what is declared here wins on every start.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon) routed services volumes;
      state = "/var/lib/sabnzbd";
      finished = "${volumes.media or state}/downloads";
      incomplete = "${volumes.scratch or state}/usenet";
      port = 8080;
      folders = [
        finished
        incomplete
      ];
    in
    {
      services.sabnzbd = {
        enable = true;
        group = "media";
        allowConfigWrite = true;
        settings = {
          misc = {
            inherit port;
            # the gateway login guards the UI; SABnzbd itself only checks the name it's reached by.
            # It listens on loopback only, so the forwarded address (a tailnet one, which it
            # doesn't count as local) has nothing to add
            host_whitelist = lib.optionalString routed services.usenet.route.host;
            verify_xff_header = false;
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

      # the folders may be on data disks that are missing at boot (nofail): wait for them, and
      # make the folders once they're mounted (tmpfiles may run before that)
      systemd.services.sabnzbd = {
        unitConfig.RequiresMountsFor = folders;
        serviceConfig.ExecStartPre = map (
          dir: "+${lib.getExe' pkgs.coreutils "install"} -d -o root -g media -m 2775 ${dir}"
        ) folders;
      };

      axon.persist.state.directories = [
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
          order = 6;
          group = "Media";
          description = "Downloads from Usenet";
          icon = "sabnzbd.svg";
          widget.type = "sabnzbd";
          key = true;
        };
        backup = {
          paths = [ state ];
          exclude = lib.optional (!volumes ? media) finished ++ lib.optional (!volumes ? scratch) incomplete;
        };
      };
    };
}
