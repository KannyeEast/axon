# DNS filtering for the tailnet (AdGuard Home). Settings are owned by Nix; the web UI is for
# looking, not changing. Point the tailnet's DNS at this host in the Tailscale admin console.
{
  flake.modules.nixos.gateway =
    { config, ... }:
    {
      config = {
        axon.persist.directories = [
          {
            directory = "/var/lib/private/AdGuardHome";
            mode = "0700";
          }
        ];

        # free port 53 for the dns to use
        services.resolved.settings.Resolve.DNSStubListener = false;

        services.adguardhome = {
          enable = true;

          # nix own the adguardhome.yaml; no changes allowed through the webui
          mutableSettings = false;

          settings = {
            http.address = "127.0.0.1:3000";

            # empty users disable adguards authenticator
            users = [ ];

            dns = {
              bind_hosts = [ "0.0.0.0" ];
              port = 53;

              upstream_dns = [
                "https://security.cloudflare-dns.com/dns-query"
                "https://dns.quad9.net/dns-query"
                "[/ts.net/]100.100.100.100"
              ];

              bootstrap_dns = [ "1.1.1.1" ];

              cache_size = 33554432; # 32 megabytes
              cache_ttl_min = 300;
              cache_ttl_max = 1800;
              cache_optimistic = true;
            };

            filtering = {
              protection_enabled = true;
              filtering_enabled = true;
            };

            filters_update_interval = 24;
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
                id = 3;
                name = "HaGeZi Microsoft (Windows, Office, MSN)";
                url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.winoffice.txt";
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

        networking.firewall.interfaces.${config.services.tailscale.interfaceName} = {
          allowedTCPPorts = [ 53 ];
          allowedUDPPorts = [ 53 ];
        };

        axon.services.dns = {
          route.port = 3000;
          backup.paths = [ "/var/lib/private/AdGuardHome" ];
        };
      };
    };
}
