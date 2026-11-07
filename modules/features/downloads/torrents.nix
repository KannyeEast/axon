# qBittorrent, locked into the VPN. Finished downloads go next to the library on the media volume
# so imports are instant, or into its state folder on a host without one. In progress on the
# scratch volume where the host has one. The module rewrites qBittorrent.conf on every start, so
# what its UI changes is gone after a restart: settings that matter belong here.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    let
      inherit (config.axon) volumes vpn;
      state = "/var/lib/qBittorrent";
      finished = "${volumes.media or state}/downloads";
      incomplete = "${volumes.scratch}/torrents";
      port = 8081;
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

      # the library is on a data disk that may be missing at boot (nofail)
      systemd.services.qbittorrent.unitConfig.RequiresMountsFor =
        lib.optional (volumes ? media) volumes.media ++ lib.optional (volumes ? scratch) volumes.scratch;

      systemd.tmpfiles.rules =
        lib.optional (volumes ? media) "d ${finished} 2775 root media -"
        ++ lib.optional (volumes ? scratch) "d ${incomplete} 2775 root media -";

      axon.persist.directories = [
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
