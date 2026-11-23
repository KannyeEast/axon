# Kanidm as the tailnet's login (Tailscale's custom OIDC): a client and the WebFinger answer on
# the bare domain, public through the tunnel; the bare domain needs its DNS record by hand.
{ lib, ... }:
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon)
        domain
        gateway
        hasSecret
        sso
        ;
      port = 8099;
      secret = "sso/tailscale";
      active = sso.provider != null && gateway.tunnel != null && hasSecret secret;
      # the address is echoed back, so only plain ones are answered
      address = "^acct:[A-Za-z0-9._+-]+@${lib.replaceStrings [ "." ] [ "[.]" ] domain}$";
      answer = lib.toJSON {
        subject = "{query.resource}";
        links = [
          {
            rel = "http://openid.net/specs/connect/1.0/issuer";
            href = sso.provider.issuer "tailscale";
          }
        ];
      };
    in
    lib.mkIf active {
      services.kanidm.provision.systems.oauth2.tailscale = {
        displayName = "Tailscale";
        originUrl = [ "https://login.tailscale.com/a/oauth_response" ];
        originLanding = "https://login.tailscale.com";
        basicSecretFile = config.sops.secrets.${secret}.path;
        # Tailscale sends no PKCE challenge
        allowInsecureClientDisablePkce = true;
        scopeMaps.admins = [
          "openid"
          "profile"
          "email"
        ];
      };

      # any name: the tunnel asks with the domain's
      services.caddy.virtualHosts."http://:${toString port}" = {
        listenAddresses = [ "127.0.0.1" ];
        extraConfig = ''
          @webfinger {
            path /.well-known/webfinger
            expression {query.resource}.matches("${address}")
          }
          header @webfinger {
            Content-Type application/jrd+json
            Access-Control-Allow-Origin *
          }
          respond @webfinger `${answer}` 200
          respond 404
        '';
      };

      services.cloudflared.tunnels.${gateway.tunnel}.ingress.${domain} =
        "http://127.0.0.1:${toString port}";

      sops.secrets.${secret}.owner = "kanidm";
    };
}
