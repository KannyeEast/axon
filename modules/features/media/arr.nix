# Finding things: Prowlarr manages the indexers for Radarr (movies) and Sonarr (shows),
# Bazarr fetches subtitles. All behind the gateway login.
{ lib, ... }:
{
  flake.modules.nixos.media =
    { config, ... }:
    let
      apps = {
        radarr = 7878;
        sonarr = 8989;
        bazarr = 6767;
      };
      prowlarr = 9696;
      vpn = config.vpnNamespaces.vpn;
    in
    {
      services.radarr = {
        enable = true;
        group = "media";
      };
      services.sonarr = {
        enable = true;
        group = "media";
      };
      services.bazarr = {
        enable = true;
        group = "media";
      };
      services.prowlarr.enable = true;

      systemd.services =
        lib.genAttrs [ "radarr" "sonarr" "bazarr" ] (_: {
          unitConfig.RequiresMountsFor = [ "/server/media" ];
          # what one app creates in the library, the others in the media group must be able to
          # write to: Bazarr puts subtitles into the folders Radarr and Sonarr make. Forced, as
          # their modules set 0022
          serviceConfig.UMask = lib.mkForce "0002";
        })
        // {
          # Prowlarr talks to the trackers' sites, so it searches through the tunnel like
          # qBittorrent downloads (downloads.nix); Radarr and Sonarr only talk to the two of them
          prowlarr = {
            vpnConfinement = {
              enable = true;
              vpnNamespace = "vpn";
            };
            # the same DNS fix as qBittorrent's, see downloads.nix
            serviceConfig.TemporaryFileSystem = [ "/run/systemd/resolve:ro" ];
          };
        };

      vpnNamespaces.vpn = {
        portMappings = [
          {
            from = prowlarr;
            to = prowlarr;
          }
        ];
        # Prowlarr hands its indexers to Radarr and Sonarr on the host; only the host's end of
        # the bridge is let past the kill switch
        allowedEgress = [ "${vpn.bridgeAddress}/32" ];
      };
      networking.firewall.interfaces.vpn-br.allowedTCPPorts = [
        apps.radarr
        apps.sonarr
      ];

      # Radarr's module only declares .config/Radarr, so tmpfiles makes .config root's and then
      # refuses the unsafe step from radarr's folder into it: Radarr is never created
      systemd.tmpfiles.settings."10-radarr"."/var/lib/radarr/.config".d = {
        user = "radarr";
        group = "media";
        mode = "0750";
      };

      axon.persist.directories =
        map (app: {
          directory = "/var/lib/${app}";
          user = app;
          group = "media";
          mode = "0750";
        }) (builtins.attrNames apps)
        ++ [
          {
            directory = "/var/lib/private/prowlarr";
            mode = "0700";
          }
        ];

      axon.services =
        lib.mapAttrs (app: port: {
          route.port = port;
          backup.paths = [ "/var/lib/${app}" ];
        }) apps
        // {
          prowlarr = {
            route = {
              port = prowlarr;
              address = vpn.namespaceAddress;
            };
            backup.paths = [ "/var/lib/private/prowlarr" ];
          };
        };
    };
}
