# AdGuard Home at dns.<domain>: DNS filtering for the tailnet.
# Reach: tailnet, the gateway's login.
# By hand: point the tailnet's DNS at this host in the Tailscale admin console.
{ lib, ... }:
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon) routes;
      inherit (config.axon.overlay) network;
      port = 3000;
      public = lib.filterAttrs (_: service: service.route.public) routes;
    in
    {
      # ── service ────────
      services.adguardhome = {
        enable = true;
        mutableSettings = false;

        settings = {
          http.address = "127.0.0.1:${toString port}";

          dns = {
            upstream_dns = [
              "https://security.cloudflare-dns.com/dns-query"
              "https://dns.quad9.net/dns-query"
            ]
            ++ lib.optional (network != null) "[/${network.domain}/]${network.resolver}";

            bootstrap_dns = [ "1.1.1.1" ];

            cache_size = 33554432; # 32 megabytes
            cache_ttl_min = 300;
            cache_ttl_max = 1800;
            cache_optimistic = true;
          };

          # lookups of its own services (the route checks) would drown out the devices' traffic
          statistics = {
            ignored = [ "||${config.axon.domain}^" ];
            ignored_enabled = true;
          };
          querylog = {
            ignored = [ "||${config.axon.domain}^" ];
            ignored_enabled = true;
          };

          # public routes answer like the start page: tailnet devices skip the tunnel's upload cap
          filtering = {
            # a name as the answer makes it a CNAME, which AdGuard then resolves upstream
            rewrites = lib.mapAttrsToList (_: service: {
              domain = service.route.host;
              answer = routes.home.route.host;
              enabled = true;
            }) public;
          };

          filters = [
            {
              enabled = true;
              id = 1;
              name = "HaGeZi Multi PRO";
              url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt";
            }
            {
              enabled = true;
              id = 2;
              name = "HaGeZi Threat Intelligence Feeds (medium)";
              url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.medium.txt";
            }
            {
              enabled = true;
              id = 4;
              name = "HaGeZi Apple (iOS, macOS, tvOS)";
              url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.apple.txt";
            }
          ];
        };
      };

      # frees port 53
      services.resolved.settings.Resolve.DNSStubListener = false;

      # ── data ────────
      axon.persist.state.directories = [
        "/var/lib/private/AdGuardHome"
      ];

      # ── contracts ────────
      axon.overlay = {
        tcpPorts = [ 53 ];
        udpPorts = [ 53 ];
      };

      # ── registration ────────
      axon.services.dns = {
        units = [ "adguardhome" ];
        route.port = port;
        # without users AdGuard's API needs no login
        dashboard = {
          name = "AdGuard Home";
          group = "Infrastructure";
          description = "DNS filtering for the tailnet";
          icon = "adguard-home.svg";
          widget.type = "adguard";
        };
        # not backed up: Nix holds the settings; the rest is query logs, statistics and filter lists
      };
    };
}
