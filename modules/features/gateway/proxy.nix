# Consumer of axon.services: every routed service that isn't public gets <subdomain>.<domain>
# on the tailnet, behind the gateway login unless it has its own.
# One wildcard certificate from Let's Encrypt via a Cloudflare DNS challenge covers them all.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatStringsSep
    elem
    filterAttrs
    length
    mapAttrs'
    nameValuePair
    optionalString
    ;
in
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon) user cluster services;

      domain =
        if cluster.domain != null then
          cluster.domain
        else
          throw "cluster.toml: the gateway feature needs a domain";
      gateways = attrNames (filterAttrs (_: data: elem "gateway" data.host.features) cluster.hosts);
      routed = filterAttrs (_: service: service.route != null && !service.route.public) services;

      # with auto_https off caddy picks no certificate itself, so every vhost names the acme files
      tls = "tls /var/lib/acme/${domain}/fullchain.pem /var/lib/acme/${domain}/key.pem";
    in
    {
      assertions = [
        {
          assertion = length gateways == 1;
          message = "cluster: exactly one host may run the gateway feature, found ${concatStringsSep ", " gateways}";
        }
      ];

      sops.secrets.cloudflare-token = { };
      sops.templates."cloudflare.env".content = ''
        CF_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-token}
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
        // mapAttrs' (
          _: service:
          nameValuePair "${service.route.subdomain}.${domain}" {
            extraConfig = ''
              ${tls}
              ${optionalString (service.route.access != "open") ''
                forward_auth 127.0.0.1:9091 {
                  uri /api/authz/forward-auth
                  copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
                }
              ''}
              reverse_proxy ${service.route.address}:${toString service.route.port}
            '';
          }
        ) routed;
      };

      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
        80
        443
      ];

      axon.persist.directories = [
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
