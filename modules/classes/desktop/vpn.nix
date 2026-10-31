# Mullvad on demand: the app connects when asked (tray, or `mullvad connect`), not at boot,
# and leaves the network alone while disconnected. Login, location and LAN sharing are
# runtime settings it keeps in /etc/mullvad-vpn.
{
  flake.modules.nixos.desktop =
    { config, pkgs, ... }:
    let
      # Mullvad's exclusion marks: traffic carrying them bypasses its tunnel and firewall
      exclude = "ct mark set 0x00000f41 meta mark set 0x6d6f6c65";
      tailnet4 = "100.64.0.0/10";
      tailnet6 = "fd7a:115c:a1e0::/48";
      rules = pkgs.writeText "mullvad-tailnet.nft" ''
        table inet mullvad-tailnet {
          chain output {
            type route hook output priority -100; policy accept;
            ip daddr ${tailnet4} ${exclude}
            ip6 daddr ${tailnet6} ${exclude}
          }
          chain input {
            type filter hook input priority -100; policy accept;
            ip saddr ${tailnet4} ${exclude}
            ip6 saddr ${tailnet6} ${exclude}
          }
        }
      '';
    in
    {
      services.mullvad-vpn = {
        enable = true;
        gui.enable = true;
      };

      # while connected, Mullvad's firewall drops everything outside its tunnel, the tailnet
      # included; marking tailnet traffic as excluded keeps node1 and the rest reachable
      systemd.services.mullvad-tailnet = {
        description = "Let tailnet traffic past Mullvad";
        wantedBy = [ "mullvad-daemon.service" ];
        before = [ "mullvad-daemon.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.nftables}/bin/nft -f ${rules}";
          ExecStop = "${pkgs.nftables}/bin/nft delete table inet mullvad-tailnet";
        };
      };

      # the login and this machine's device key: without them every boot registers a new
      # device, and an account has five
      axon.persist.directories = [
        {
          directory = "/etc/mullvad-vpn";
          mode = "0700";
        }
        "/var/cache/mullvad-vpn"
      ];
    };
}
