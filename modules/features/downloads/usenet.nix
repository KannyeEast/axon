# SABnzbd at usenet.<domain>: Usenet downloads, outside the VPN (its provider connection is SSL).
# Reach: tailnet, the gateway's login.
# In its UI only: the provider and its connections, in sabnzbd.ini, backed up.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        hasSecret
        routed
        services
        volumes
        ;
      inherit (config.axon.services.usenet) route;
      port = 8080;
      state = "/var/lib/sabnzbd";
      finished = "${volumes.media or state}/downloads";
      incomplete = "${volumes.scratch or state}/usenet";
      # without it in secrets.json, SABnzbd keeps the key it made itself
      key = services.usenet.apiKey;
      folders = [
        finished
        incomplete
      ];
    in
    {
      # ── service ────────
      services.sabnzbd = {
        enable = true;
        group = "media";
        allowConfigWrite = true;
        settings = {
          misc = {
            inherit port;
            # only the tailnet reaches the UI; SABnzbd only checks the name it's reached by. It
            # listens on loopback, so the forwarded address (tailnet, not local to it) adds nothing
            host_whitelist = lib.optionalString routed route.host;
            verify_xff_header = false;
            download_dir = incomplete;
            complete_dir = finished;
            # Radarr and Sonarr, in the media group, move and delete what lands here
            permissions = "775";
            api_key = lib.mkIf (hasSecret key) "@api_key@";
            # unset, every article goes straight to disk; new installs default to at most this
            cache_limit = "1G";
            # its web UI's one-time tips message, seen
            notified_new_skin = 2;
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
        secretValues = lib.mkIf (hasSecret key) { "@api_key@" = config.sops.secrets.${key}.path; };
      };

      # ── units ────────
      # the folders may be on data disks that are missing at boot (nofail): wait for them, and
      # make the folders once they're mounted (tmpfiles may run before that)
      systemd.services.sabnzbd = {
        unitConfig.RequiresMountsFor = folders;
        serviceConfig = {
          ExecStartPre = map (
            dir: "+${lib.getExe' pkgs.coreutils "install"} -d -o root -g media -m 2775 ${dir}"
          ) folders;
          # the module forks it (-d); in the foreground it also logs to the journal, not only to
          # its own file
          Type = lib.mkForce "simple";
          ExecStart = lib.mkForce "${lib.getExe config.services.sabnzbd.package} -f ${state}/sabnzbd.ini";
          # systemd sets it on every start, over the mode the folder was made with
          StateDirectoryMode = "0750";
        };
      };

      # ── secrets ────────
      # read by its preStart, which runs as sabnzbd
      sops.secrets.${key} = lib.mkIf (hasSecret key) {
        owner = config.services.sabnzbd.user;
        restartUnits = [ "sabnzbd.service" ];
      };

      # ── data ────────
      axon.persist.state.directories = [
        {
          directory = state;
          user = "sabnzbd";
          group = "media";
          mode = "0750";
        }
      ];

      # ── registration ────────
      axon.services.usenet = {
        units = [ "sabnzbd" ];
        route = { inherit port; };
        dashboard = {
          name = "SABnzbd";
          order = 4;
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
