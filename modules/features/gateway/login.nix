# oauth2-proxy at login.<domain>: the login in front of every route with gate (by default every
# tailnet-only one), for the provider's (axon.sso) admins group. The gateway (proxy.nix) asks it on
# each request to a gated route; one cookie for the whole domain covers them all. Without a provider or its secrets (sso/proxy, the
# client secret, and sso/proxy-cookie) it doesn't run and gated routes stay open, with a warning.
{ lib, ... }:
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon)
        domain
        host
        routes
        sso
        ;
      inherit (config.axon.services.login) route;
      client = sso.clients.proxy;
      port = 4180;
      secrets = [
        "sso/proxy"
        "sso/proxy-cookie"
      ];
      missing = lib.filter (
        secret: !lib.hasAttrByPath (lib.splitString "/" secret) config.axon.secrets
      ) secrets;
      active = sso.provider != null && missing == [ ];
      gated = lib.attrNames (lib.filterAttrs (_: service: service.route.gate) routes);
      open = lib.attrNames (
        lib.filterAttrs (_: service: service.route.gate && service.route.public) routes
      );
    in
    {
      assertions = [
        {
          assertion = open == [ ];
          message = "axon.services: ${lib.concatStringsSep ", " open} set gate and public; the tunnel bypasses the gate, so drop one";
        }
      ];

      warnings = lib.optional (gated != [ ] && !active) (
        if sso.provider == null then
          "axon.sso.provider: null, so ${lib.concatStringsSep ", " gated} have no login"
        else
          "hosts/${host.name}/secrets.json: no ${lib.concatStringsSep ", " missing}, so ${lib.concatStringsSep ", " gated} have no login; add them with `just secrets ${host.name}`"
      );

      sops.secrets."sso/proxy-cookie" = lib.mkIf active { };

      services.oauth2-proxy = lib.mkIf active {
        enable = true;
        httpAddress = "http://127.0.0.1:${toString port}";
        provider = "oidc";
        clientID = client.id;
        clientSecretFile = client.secret;
        oidcIssuerUrl = client.issuer;
        redirectURL = "${route.url}/oauth2/callback";
        scope = "openid email profile groups";
        email.domains = [ "*" ];
        cookie = {
          domain = ".${domain}";
          secretFile = config.sops.secrets."sso/proxy-cookie".path;
        };
        reverseProxy = true;
        # a line per gated request, with the full URL: SABnzbd's web UI puts its API key in it
        requestLogging = false;
        trustedProxyIP = [ "127.0.0.1" ];
        extraConfig = {
          # Kanidm refuses a client without PKCE
          code-challenge-method = "S256";
          cookie-samesite = "lax";
          skip-provider-button = true;
          # where the login may send the browser back to
          whitelist-domain = ".${domain}";
          # Kanidm lists groups as <name>@<its domain>
          allowed-group = "${client.group}@${lib.removePrefix "https://" sso.provider}";
        };
      };

      # it reads the provider's discovery document through the gateway at start and exits without
      # it, so it retries until Kanidm is up
      systemd.services.oauth2-proxy = lib.mkIf active (
        let
          units = [ "caddy.service" ] ++ lib.optional (sso.unit != null) sso.unit;
        in
        {
          wants = units;
          after = units;
          serviceConfig.RestartSec = "10s";
          unitConfig.StartLimitIntervalSec = 0;
        }
      );

      axon.sso.clients.proxy = lib.mkIf active {
        displayName = "Tailnet apps";
        landing = config.axon.services.home.route.url;
        redirects = [ "${route.url}/oauth2/callback" ];
        group = "admins";
        user = "oauth2-proxy";
      };

      axon.services.login = {
        units = lib.mkIf active [ "oauth2-proxy" ];
        route = lib.mkIf active {
          inherit port;
          # it is the login
          gate = false;
        };
      };
    };
}
