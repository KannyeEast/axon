# Kanidm as the tailnet's login (Tailscale's custom OIDC): a client for Tailscale, and the
# WebFinger answer on the bare domain that points Tailscale at it, public through the tunnel. The
# login is srv-auth@<domain>: a Kanidm person with that mail, made by hand. On with sso/tailscale
# in secrets.json and a tunnel; the bare domain needs its DNS record, like a public route.
{ lib, ... }:
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon)
        domain
        gateway
        sso
        ;
      port = 8099;
      secret = "sso/tailscale";
      issuer = "${sso.provider}/oauth2/openid/tailscale";
      active =
        sso.provider != null
        && gateway.tunnel != null
        && lib.hasAttrByPath (lib.splitString "/" secret) config.axon.secrets;
      address = "srv-auth@${domain}";
      answer = lib.toJSON {
        subject = "acct:${address}";
        links = [
          {
            rel = "http://openid.net/specs/connect/1.0/issuer";
            href = issuer;
          }
        ];
      };
    in
    lib.mkIf active {
      sops.secrets.${secret}.owner = "kanidm";

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
            query resource=acct:${address}
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
    };
}
