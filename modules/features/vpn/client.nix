# Mullvad on demand on desktops: the app connects when asked (tray, or `mullvad connect`), not at
# boot, and leaves the network alone while disconnected. Login, location and LAN sharing are
# runtime settings it keeps in /etc/mullvad-vpn.
{ lib, ... }:
{
  flake.modules.nixos.vpn =
    { config, pkgs, ... }:
    let
      inherit (config.axon.overlay) network;
      nft = lib.getExe pkgs.nftables;
      # Mullvad's exclusion marks: traffic carrying them bypasses its tunnel and firewall
      exclude = "ct mark set 0x00000f41 meta mark set 0x6d6f6c65";
      rules = pkgs.writeText "mullvad-tailnet.nft" ''
        table inet mullvad-tailnet {
          chain output {
            type route hook output priority -100; policy accept;
            ip daddr ${network.ipv4} ${exclude}
            ip6 daddr ${network.ipv6} ${exclude}
          }
          chain input {
            type filter hook input priority -100; policy accept;
            ip saddr ${network.ipv4} ${exclude}
            ip6 saddr ${network.ipv6} ${exclude}
          }
        }
      '';
    in
    lib.mkIf (config.axon.host.class == "desktop") {
      services.mullvad-vpn = {
        enable = true;
        gui.enable = true;
      };

      # while connected, Mullvad's firewall drops everything outside its tunnel, the tailnet
      # included; marking tailnet traffic as excluded keeps the other machines reachable
      systemd.services.mullvad-tailnet = lib.mkIf (network != null) {
        description = "Let tailnet traffic past Mullvad";
        wantedBy = [ "mullvad-daemon.service" ];
        before = [ "mullvad-daemon.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${nft} -f ${rules}";
          ExecStop = "${nft} delete table inet mullvad-tailnet";
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
