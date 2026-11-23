# qBittorrent at downloads.<domain>: torrents, locked into the VPN.
# Reach: tailnet, the gateway's login only.
# In its UI only: nothing that lasts; the module rewrites qBittorrent.conf on every start.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    let
      inherit (config.axon) volumes vpn;
      port = 8081;
      state = "/var/lib/qBittorrent";
      # next to the library, so imports are instant
      finished = "${volumes.media or state}/downloads";
      incomplete = "${volumes.scratch}/torrents";
      folders = [ finished ] ++ lib.optional (volumes ? scratch) incomplete;
    in
    {
      # ── service ────────
      services.qbittorrent = {
        enable = true;
        group = "media";
        webuiPort = port;
        serverConfig = {
          LegalNotice.Accepted = true;
          BitTorrent.Session = {
            DefaultSavePath = finished;
            GlobalMaxRatio = 0; # stop as soon as it's done: nothing seeds
            # a series queues up and works through by itself; a torrent without peers blocks nothing
            QueueingSystemEnabled = true;
            IgnoreSlowTorrentsForQueueing = true;
            MaxActiveDownloads = 5;
            MaxActiveTorrents = 5;
          }
          // lib.optionalAttrs (volumes ? scratch) {
            TempPathEnabled = true;
            TempPath = incomplete;
          };
          # no password: only the gateway reaches the UI, and nothing else is in the namespace
          WebUI = {
            AuthSubnetWhitelistEnabled = true;
            AuthSubnetWhitelist = "${vpn.network.subnet}, 127.0.0.1/32";
          };
        };
      };
      users.groups.media = { };

      # ── units ────────
      # downloads group-writable: Radarr and Sonarr may only hardlink, move or delete what they
      # can write (fs.protected_hardlinks); read-only, the import fails
      systemd.services.qbittorrent.serviceConfig.UMask = "0002";

      # ── data ────────
      axon.folders = lib.genAttrs folders (_: {
        user = "root";
        group = "media";
        mode = "2775";
        units = [ "qbittorrent" ];
      });

      # no StateDirectory, and its module's tmpfiles make only subfolders: impermanence makes this one
      axon.persist.state.directories = [
        {
          directory = state;
          user = "qbittorrent";
          group = "media";
          mode = "0750";
        }
      ];

      # ── contracts ────────
      axon.vpn.confined.qbittorrent.ports = [ port ];

      # ── registration ────────
      axon.services.downloads = {
        units = [ "qbittorrent" ];
        route = {
          inherit port;
          inherit (vpn.network) address;
        };
        # the subnet whitelist above lets the widget in without a login
        dashboard = {
          name = "qBittorrent";
          order = 3;
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
