# qBittorrent, locked into a network namespace whose only way out is Mullvad over WireGuard:
# if the tunnel drops, it has no network at all. Its web UI is reachable from the host through
# the namespace bridge (192.168.15.1). Mullvad has no port forwarding, so other peers can't
# connect to it: downloads work, seeding only reaches peers that are themselves reachable.
# In progress on the scratch SSD, finished on the bulk disks next to the library.
{ inputs, ... }:
{
  flake.modules.nixos.media =
    { config, ... }:
    let
      port = 8081;
      incomplete = "/server/scratch/torrents";
    in
    {
      imports = [ inputs.vpn-confinement.nixosModules.default ];

      # a wg-quick file from Mullvad's config generator
      sops.secrets.mullvad-wireguard = { };

      vpnNamespaces.vpn = {
        enable = true;
        wireguardConfigFile = config.sops.secrets.mullvad-wireguard.path;
        # not the bridge's own 192.168.15.0/24: the namespace already has that route, and
        # VPN-Confinement fails adding it twice ("RTNETLINK answers: File exists")
        accessibleFrom = [ "127.0.0.1/32" ];
        portMappings = [
          {
            from = port;
            to = port;
          }
        ];
      };

      services.qbittorrent = {
        enable = true;
        group = "media";
        webuiPort = port;
        serverConfig = {
          LegalNotice.Accepted = true;
          Preferences = {
            Downloads = {
              SavePath = "/server/media/downloads";
              TempPathEnabled = true;
              TempPath = incomplete;
            };
            # the gateway login guards the UI; inside the namespace nothing else can reach it
            WebUI.AuthSubnetWhitelistEnabled = true;
            WebUI.AuthSubnetWhitelist = "192.168.15.0/24, 127.0.0.1/32";
          };
        };
      };

      systemd.services.qbittorrent = {
        vpnConfinement = {
          enable = true;
          vpnNamespace = "vpn";
        };
        unitConfig.RequiresMountsFor = [
          "/server/media"
          "/server/scratch"
        ];
        # glibc asks systemd-resolved first, through a socket VPN-Confinement leaves open; that
        # resolver runs outside the tunnel. Without it, lookups go to the tunnel's own DNS.
        serviceConfig.InaccessiblePaths = [ "/run/systemd/resolve" ];
      };

      systemd.tmpfiles.rules = [ "d ${incomplete} 2775 root media -" ];

      axon.persist.directories = [
        {
          directory = "/var/lib/qBittorrent";
          user = "qbittorrent";
          group = "media";
          mode = "0750";
        }
      ];

      axon.services.downloads = {
        route = {
          inherit port;
          address = "192.168.15.1";
        };
        backup.paths = [ "/var/lib/qBittorrent" ];
      };
    };
}
