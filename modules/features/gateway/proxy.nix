# Consumer of axon.services: every routed service gets <service>.<domain> on the tailnet,
# behind the gateway login unless it has its own. Public ones are on the tunnel as well.
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

      # caddy gets no certificates itself (auto_https disable_certs), so every vhost names the acme files
      tls = "tls /var/lib/acme/${domain}/fullchain.pem /var/lib/acme/${domain}/key.pem";
    in
    {
      axon.routed = true;

      assertions = [
        {
          assertion = lib.length gateways == 1;
          message = "cluster.toml: exactly one host may run the gateway feature, found ${lib.concatStringsSep ", " gateways}";
        }
      ];

      sops.secrets.cloudflare-token = { };
      sops.templates."cloudflare.env".content = ''
        CF_DNS_API_TOKEN=${ph.cloudflare-token}
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
          group = config.services.caddy.group;
          reloadServices = [ "caddy.service" ];
        };
      };

      services.caddy = {
        enable = true;
        globalConfig = "auto_https disable_certs";
        virtualHosts = {
          # anything not routed below
          "*.${domain}".extraConfig = ''
            ${tls}
            abort
          '';
        }
        // lib.mapAttrs' (
          _: service:
          lib.nameValuePair service.route.host {
            extraConfig = ''
              ${tls}
              ${lib.optionalString (service.route.access != "open") ''
                forward_auth ${routes.auth.route.endpoint} {
                  uri /api/authz/forward-auth
                  copy_headers Remote-User
                }
              ''}
              # services that trust Cloudflare's client-address header must not take it from a
              # tailnet client; the tunnel bypasses Caddy, so here it is always the real peer
              reverse_proxy ${service.route.endpoint} {
                header_up Cf-Connecting-IP {remote_host}
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
