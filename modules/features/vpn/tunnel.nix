# Mullvad over WireGuard in a namespace for what axon.vpn.confined lists, which has no network
# without the tunnel. Mullvad has no port forwarding, so peers can't connect in.
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
          subnet = "${namespace.bridgeAddress}/24";
        };

        axon.links.Mullvad = {
          url = "https://mullvad.net/en/account";
          icon = "mullvad.svg";
        };

        # a wg-quick file from Mullvad's config generator
        sops.secrets."mullvad/wireguard" = { };

        vpnNamespaces.vpn = {
          wireguardConfigFile = config.sops.secrets."mullvad/wireguard".path;
          # not the bridge's own subnet: the namespace already has that route, and
          # VPN-Confinement fails adding it twice ("RTNETLINK answers: File exists")
          allowedIngress = [ "127.0.0.1/32" ];
          portMappings = lib.concatMap (
            service:
            map (port: {
              from = port;
              to = port;
            }) service.ports
          ) (lib.attrValues vpn.confined);
        };

        systemd.services = lib.mapAttrs (_: _: {
          vpnConfinement = {
            enable = true;
            vpnNamespace = "vpn";
          };
          # glibc asks systemd-resolved first, which runs outside the tunnel (a DNS leak); an empty
          # folder over its socket makes it look absent, so lookups go to the tunnel's own DNS
          serviceConfig.TemporaryFileSystem = [ "/run/systemd/resolve:ro" ];
        }) vpn.confined;
      };
    };
}
