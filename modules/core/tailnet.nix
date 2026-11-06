# Contract: axon.overlay. The private network between machines, here Tailscale; cluster relations
# (ssh, sync) run over it. A host joins by being named in a relation in cluster.toml; any other
# host stays off it and needs no key. Features list the ports they serve on it and those stay
# closed on a host outside it. network is null there.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    attrValues
    concatLists
    elem
    mkIf
    mkOption
    types
    ;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) cluster host overlay;
      member = elem host.name (
        attrNames cluster.ssh ++ concatLists (attrValues cluster.ssh ++ attrValues cluster.sync)
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

      config = mkIf member {
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

        axon.persist.directories = [
          {
            directory = "/var/lib/tailscale";
            mode = "0700";
          }
        ];
      };
    };
}
