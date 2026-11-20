# Consumer of axon.services: every routed service gets <service>.<domain> on the tailnet, proxied
# as is; a login is the service's own, or with gate the one at login.<domain> (login.nix). Public
# ones are on the tunnel as well.
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
      login = config.axon.services.login.route;
      gateways = lib.attrNames (
        lib.filterAttrs (_: data: lib.elem "gateway" data.host.features) cluster.hosts
      );
    in
    {
      axon.routed = true;

      assertions = [
        {
          assertion = lib.length gateways == 1;
          message = "${
            lib.concatMapStringsSep ", " (name: "hosts/${name}/host.toml") gateways
          }: only one host may list the gateway feature; keep it on one";
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
            extraConfig =
              lib.optionalString (service.route.gate && config.services.oauth2-proxy.enable) ''
                forward_auth ${login.endpoint} {
                  uri /oauth2/auth
                  @login status 401
                  handle_response @login {
                    redir * ${login.url}/oauth2/start?rd={scheme}://{host}{http.request.uri_escaped}
                  }
                }
              ''
              + ''
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
