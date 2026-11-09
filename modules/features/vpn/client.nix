# Mullvad on demand on desktops: the app connects when asked (tray, or `mullvad connect`), not at
# boot, and leaves the network alone while disconnected. Login, location and LAN sharing are
# runtime settings it keeps in /etc/mullvad-vpn. `mullvad-country` steps the location through
# Mullvad's own country list (next/prev [n]), toggles the tunnel and prints the state, for a dial.
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
        text = ''
          # "<code> <name>" per country, in Mullvad's order; the location set now, if it is one
          countries() { mullvad relay list | sed -n 's/^\([A-Z].*\) (\([a-z][a-z]\))$/\2 \1/p'; }
          current() { mullvad relay get | awk '$1 == "Location:" { print $3; exit }'; }
          status() { mullvad status | head -n 1; }

          case "''${1:-show}" in
            next | prev)
              mapfile -t list < <(countries)
              here=$(current)
              # with no country set (any), next starts at the first and prev at the last
              index=-1
              for i in "''${!list[@]}"; do
                [ "''${list[$i]%% *}" = "$here" ] && index=$i
              done
              step=''${2:-1}
              [ "$1" = prev ] && step=$((-step))
              [ "$index" = -1 ] && [ "$1" = prev ] && index=0
              index=$(((index + step) % ''${#list[@]} + ''${#list[@]}))
              mullvad relay set location "''${list[$((index % ''${#list[@]}))]%% *}" >/dev/null
              ;;
            toggle)
              case $(status) in
                Connected* | Connecting*) mullvad disconnect >/dev/null ;;
                *) mullvad connect >/dev/null ;;
              esac
              ;;
            show)
              case $(status) in
                Connected*) level=on ;;
                Connecting*) level=warn ;;
                *) level=off ;;
              esac
              here=$(current)
              name=$(countries | awk -v c="$here" '$1 == c { $1 = ""; sub(/^ /, ""); print; exit }')
              echo "$level ''${name:-any}"
              ;;
            *)
              echo "mullvad-country: unknown command '$1', expected next|prev [n], toggle or show" >&2
              exit 1
              ;;
          esac
        '';
      };
    in
    lib.mkIf (config.axon.host.class == "desktop") {
      services.mullvad-vpn = {
        enable = true;
        gui.enable = true;
      };
      environment.systemPackages = [ country ];

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
      axon.persist.state.directories = [
        {
          directory = "/etc/mullvad-vpn";
          mode = "0700";
        }
        "/var/cache/mullvad-vpn"
      ];
    };
}
