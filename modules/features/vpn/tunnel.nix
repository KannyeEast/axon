# Mullvad over WireGuard in a network namespace on servers. Whatever axon.vpn.confined lists runs
# inside it, and if the tunnel drops that service has no network at all. The host reaches those
# services through the namespace bridge (axon.vpn.network.address). Mullvad has no port forwarding, so
# peers can't connect in: downloads work, seeding only reaches peers that are themselves reachable.
{ inputs, lib, ... }:
{
  flake.modules.nixos.vpn =
    { config, ... }:
    let
      inherit (config.axon) host vpn;
      namespace = config.vpnNamespaces.vpn;
    in
    {
      imports = [ inputs.vpn-confinement.nixosModules.default ];

      config = lib.mkIf (host.class == "server") {
        axon.vpn.network = {
          address = namespace.namespaceAddress;
          subnet = "192.168.15.0/24";
        };

        axon.links.Mullvad = {
          url = "https://mullvad.net/en/account";
          icon = "mullvad.svg";
        };

        # a wg-quick file from Mullvad's config generator
        sops.secrets.mullvad-wireguard = { };

        vpnNamespaces.vpn = {
          enable = true;
          wireguardConfigFile = config.sops.secrets.mullvad-wireguard.path;
          # not the bridge's own subnet: the namespace already has that route, and
          # VPN-Confinement fails adding it twice ("RTNETLINK answers: File exists")
          accessibleFrom = [ "127.0.0.1/32" ];
          portMappings = lib.concatMap (
            service:
            map (port: {
              from = port;
              to = port;
            }) service.ports
          ) (lib.attrValues vpn.confined);
          # only the host's end of the bridge is let past the kill switch
          allowedEgress = lib.optional (vpn.hostPorts != [ ]) "${namespace.bridgeAddress}/32";
        };
        networking.firewall.interfaces.vpn-br.allowedTCPPorts = vpn.hostPorts;

        systemd.services = lib.mapAttrs (_: _: {
          vpnConfinement = {
            enable = true;
            vpnNamespace = "vpn";
          };
          # glibc asks systemd-resolved first, through a socket VPN-Confinement leaves open; that
          # resolver runs outside the tunnel. An empty folder over it makes resolved look absent,
          # so lookups go on to the tunnel's own DNS.
          serviceConfig.TemporaryFileSystem = [ "/run/systemd/resolve:ro" ];
        }) vpn.confined;
      };
    };
}
