# Contract: axon.overlay. The private network between machines (Tailscale) that cluster relations
# run over. A host joins by being named in a cluster.toml relation; any other stays off, needs no
# key, keeps the listed ports closed and has a null network.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) cluster host overlay;
      member = lib.elem host.name (
        lib.attrNames cluster.ssh
        ++ lib.concatLists (lib.attrValues cluster.ssh ++ lib.attrValues cluster.sync)
      );
    in
    {
      options.axon.overlay = {
        network = mkOption {
          default = null;
          description = "The network this host is on. Null on a host outside it; consumers must work with that.";
          type = types.nullOr (
            types.submodule {
              options = {
                ipv4 = mkOption {
                  type = types.str;
                  description = "Addresses of its members.";
                };
                ipv6 = mkOption {
                  type = types.str;
                  description = "Addresses of its members.";
                };
                domain = mkOption {
                  type = types.str;
                  description = "Domain its members' names end in.";
                };
                resolver = mkOption {
                  type = types.str;
                  description = "DNS server that answers for that domain.";
                };
              };
            }
          );
        };
        tcpPorts = mkOption {
          type = types.listOf types.port;
          default = [ ];
          description = "TCP ports this host serves to the other members.";
        };
        udpPorts = mkOption {
          type = types.listOf types.port;
          default = [ ];
          description = "UDP ports this host serves to the other members.";
        };
      };

      config = lib.mkIf member {
        axon.overlay.network = {
          ipv4 = "100.64.0.0/10";
          ipv6 = "fd7a:115c:a1e0::/48";
          domain = "ts.net";
          resolver = "100.100.100.100";
        };

        sops.secrets.tailscale-authkey = { };

        services.tailscale = {
          enable = true;
          openFirewall = true;
          authKeyFile = config.sops.secrets.tailscale-authkey.path;
        };
        services.resolved.enable = true; # MagicDNS

        networking.firewall.interfaces.${config.services.tailscale.interfaceName} = {
          allowedTCPPorts = overlay.tcpPorts;
          allowedUDPPorts = overlay.udpPorts;
        };

        axon.links.Tailscale = {
          url = "https://console.tailscale.com";
          icon = "tailscale.svg";
        };

        axon.persist.directories = [
          {
            directory = "/var/lib/tailscale";
            mode = "0700";
          }
        ];
      };
    };
}
