# Contract: axon.vpn. A tunnel that services are locked into, so they have no network outside it.
# A service lists itself under confined and the vpn feature does the locking. A host without a
# tunnel refuses to build such a service: running it would send its traffic out in the open.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) host vpn;
    in
    {
      options.axon.vpn = {
        network = mkOption {
          default = null;
          description = "The tunnel on this host, set by the vpn feature. Null on a host without one.";
          type = types.nullOr (
            types.submodule {
              options = {
                address = mkOption {
                  type = types.str;
                  description = "Where the host reaches a confined service.";
                };
                subnet = mkOption {
                  type = types.str;
                  description = "The range both ends of the link between the host and the tunnel sit in.";
                };
              };
            }
          );
        };
        confined = mkOption {
          default = { };
          description = "Systemd services to lock into the tunnel.";
          type = types.attrsOf (
            types.submodule {
              options.ports = mkOption {
                type = types.listOf types.port;
                default = [ ];
                description = "TCP ports of the service the host can reach.";
              };
            }
          );
        };
        hostPorts = mkOption {
          type = types.listOf types.port;
          default = [ ];
          description = "TCP ports on the host that confined services may reach.";
        };
      };

      config.assertions = [
        {
          assertion = vpn.confined == { } || vpn.network != null;
          message = "hosts/${host.name}/host.toml: ${lib.concatStringsSep ", " (lib.attrNames vpn.confined)} must run inside a tunnel but this host has none; list the vpn feature here";
        }
      ];
    };
}
