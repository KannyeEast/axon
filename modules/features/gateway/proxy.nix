# Consumer of axon.services: every routed service gets <service>.<domain> on the tailnet, proxied
# as is; a login is the service's own. Public ones are on the tunnel as well.
# One wildcard certificate from Let's Encrypt via a Cloudflare DNS challenge covers them all.
{ lib, ... }:
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon)
        user
        cluster
        domain
        routes
        ;

      ph = config.sops.placeholder;
      gateways = lib.attrNames (
        lib.filterAttrs (_: data: lib.elem "gateway" data.host.features) cluster.hosts
      );
    in
    {
      axon.routed = true;

      assertions = [
        {
          assertion = lib.length gateways == 1;
          message = "cluster.toml: exactly one host may run the gateway feature, found ${lib.concatStringsSep ", " gateways}";
        }
      ];

      sops.secrets."cloudflare/dns-token" = { };
      sops.templates."cloudflare.env".content = ''
        CF_DNS_API_TOKEN=${ph."cloudflare/dns-token"}
      '';

      security.acme = {
        acceptTerms = true;
        defaults.email = user.email;
        certs.${domain} = {
          inherit domain;
          extraDomainNames = [ "*.${domain}" ];
          dnsProvider = "cloudflare";
          dnsResolver = "1.1.1.1:53";
          environmentFile = config.sops.templates."cloudflare.env".path;
        };
      };

      services.caddy = {
        enable = true;
        virtualHosts = {
          # anything not routed below
          "*.${domain}" = {
            useACMEHost = domain;
            extraConfig = "abort";
          };
        }
        // lib.mapAttrs' (
          _: service:
          lib.nameValuePair service.route.host {
            useACMEHost = domain;
            extraConfig = ''
              # services that trust Cloudflare's client-address header must not take it from a
              # tailnet client; the tunnel bypasses Caddy, so here it is always the real peer
              reverse_proxy ${service.route.internal} {
                header_up Cf-Connecting-IP {remote_host}
                ${lib.optionalString service.route.tls ''
                  transport http {
                    tls_server_name ${service.route.host}
                  }
                ''}
              }
            '';
          }
        ) routes;
      };

      axon.overlay.tcpPorts = [
        80
        443
      ];

      axon.links.Cloudflare = {
        url = "https://dash.cloudflare.com";
        icon = "cloudflare.svg";
      };

      axon.persist.state.directories = [
        {
          directory = "/var/lib/caddy";
          user = "caddy";
          group = "caddy";
          mode = "0700";
        }
        "/var/lib/acme"
      ];
    };
}
