# qBittorrent, locked into the VPN. Finished downloads go next to the library on the media volume
# so imports are instant, or into its state folder on a host without one. In progress on the
# scratch volume where the host has one. The module rewrites qBittorrent.conf on every start, so
# what its UI changes is gone after a restart: settings that matter belong here.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon) volumes vpn;
      state = "/var/lib/qBittorrent";
      finished = "${volumes.media or state}/downloads";
      incomplete = "${volumes.scratch}/torrents";
      port = 8081;
      folders = [ finished ] ++ lib.optional (volumes ? scratch) incomplete;
    in
    {
      users.groups.media = { };

      axon.vpn.confined.qbittorrent.ports = [ port ];

      services.qbittorrent = {
        enable = true;
        group = "media";
        webuiPort = port;
        serverConfig = {
          LegalNotice.Accepted = true;
          BitTorrent.Session = {
            DefaultSavePath = finished;
            GlobalMaxRatio = 0; # stop as soon as it's done: nothing seeds
            # a whole series queues up and works through by itself; a torrent without peers doesn't
            # hold up the rest
            QueueingSystemEnabled = true;
            IgnoreSlowTorrentsForQueueing = true;
            MaxActiveDownloads = 5;
            MaxActiveTorrents = 5;
          }
          // lib.optionalAttrs (volumes ? scratch) {
            TempPathEnabled = true;
            TempPath = incomplete;
          };
          # the gateway login guards the UI; inside the namespace nothing else can reach it
          WebUI = {
            AuthSubnetWhitelistEnabled = true;
            AuthSubnetWhitelist = "${vpn.network.subnet}, 127.0.0.1/32";
          };
        };
      };

      # the folders may be on data disks that are missing at boot (nofail): wait for them, and
      # make the folders once they're mounted (tmpfiles may run before that)
      systemd.services.qbittorrent = {
        unitConfig.RequiresMountsFor = folders;
        serviceConfig.ExecStartPre = map (
          dir: "+${lib.getExe' pkgs.coreutils "install"} -d -o root -g media -m 2775 ${dir}"
        ) folders;
      };

      axon.persist.state.directories = [
        {
          directory = state;
          user = "qbittorrent";
          group = "media";
          mode = "0750";
        }
      ];

      axon.services.downloads = {
        route = {
          inherit port;
          inherit (vpn.network) address;
        };
        # the subnet whitelist above lets the widget in without a login
        dashboard = {
          name = "qBittorrent";
          order = 2;
          group = "Media";
          description = "Downloads through the VPN";
          icon = "qbittorrent.svg";
          widget.type = "qbittorrent";
        };
        backup = {
          paths = [ state ];
          exclude = lib.optional (!volumes ? media) finished;
        };
      };
    };
}
