# qBittorrent, locked into the VPN. Finished downloads go next to the library on the media volume
# so imports are instant, or into its state folder on a host without one. In progress on the
# scratch volume where the host has one.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    let
      inherit (config.axon) volumes vpn;
      media = volumes.media or null;
      scratch = volumes.scratch or null;
      state = "/var/lib/qBittorrent";
      finished = "${volumes.media or state}/downloads";
      incomplete = "${scratch}/torrents";
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
          Preferences = {
            Downloads = {
              SavePath = finished;
            }
            // lib.optionalAttrs (scratch != null) {
              TempPathEnabled = true;
              TempPath = incomplete;
            };
            # the gateway login guards the UI; inside the namespace nothing else can reach it
            WebUI.AuthSubnetWhitelistEnabled = true;
            WebUI.AuthSubnetWhitelist = "${vpn.subnet}, 127.0.0.1/32";
          };
        };
      };

      # the library is on a data disk that may be missing at boot (nofail)
      systemd.services.qbittorrent.unitConfig.RequiresMountsFor =
        lib.optional (media != null) media ++ lib.optional (scratch != null) scratch;

      systemd.tmpfiles.rules =
        lib.optional (media != null) "d ${finished} 2775 root media -"
        ++ lib.optional (scratch != null) "d ${incomplete} 2775 root media -";

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
          inherit (vpn) address;
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
          exclude = lib.optional (media == null) finished;
        };
      };
    };
}
