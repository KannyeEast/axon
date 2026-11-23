# Mullvad: the VPN on demand, connected when asked (tray or `mullvad connect`), not at boot.
# Settings: none; login, location and LAN sharing are set in the app and kept in /etc/mullvad-vpn.
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

      country = pkgs.writeShellApplication {
        name = "mullvad-country";
        runtimeInputs = [
          config.services.mullvad-vpn.package
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnused
        ];
        text = builtins.readFile ./_mullvad-country.sh;
      };
    in
    lib.mkIf (config.axon.host.class == "desktop") {
      # ── service ────────
      services.mullvad-vpn = {
        enable = true;
        gui.enable = true;
      };

      # ── program ────────
      environment.systemPackages = [ country ];

      # ── units ────────
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

      # ── data ────────
      # login and device key: else every boot registers a new device, and an account has five
      axon.persist.state.directories = [
        {
          directory = "/etc/mullvad-vpn";
          mode = "0700";
        }
        "/var/cache/mullvad-vpn"
      ];
    };
}
