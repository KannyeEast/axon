# oauth2-proxy at login.<domain>: the gateway's login in front of every gated route, for admins.
# Reach: tailnet, no login.
{ lib, ... }:
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon)
        domain
        hasSecret
        host
        routes
        sso
        ;
      inherit (config.axon.services.login) route;
      port = 4180;
      secrets = [
        "login/sso"
        "login/cookie"
      ];
      client = sso.clients.proxy;
      missing = lib.filter (secret: !hasSecret secret) secrets;
      active = sso.provider != null && missing == [ ];
      gated = lib.attrNames (lib.filterAttrs (_: service: service.route.gate) routes);
      open = lib.attrNames (
        lib.filterAttrs (_: service: service.route.gate && service.route.public) routes
      );
    in
    {
      # ── service ────────
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
          secretFile = config.sops.secrets."login/cookie".path;
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
          whitelist-domain = ".${domain}";
          allowed-group = client.groupClaim;
        };
      };

      # ── units ────────
      # it exits when the provider's discovery document isn't there yet, so it retries
      systemd.services.oauth2-proxy = lib.mkIf active {
        wants = sso.provider.units;
        serviceConfig.RestartSec = "10s";
        unitConfig.StartLimitIntervalSec = 0;
      };

      # ── secrets ────────
      sops.secrets."login/cookie" = lib.mkIf active { };

      # ── login ────────
      axon.sso.clients.proxy = lib.mkIf active {
        service = "login";
        displayName = "Tailnet apps";
        landing = config.axon.services.home.route.url;
        redirects = [ "${route.url}/oauth2/callback" ];
        group = "admins";
        user = "oauth2-proxy";
      };

      # ── contracts ────────
      axon.gated = active;

      # ── registration ────────
      axon.services.login = {
        units = lib.mkIf active [ "oauth2-proxy" ];
        route = lib.mkIf active {
          inherit port;
          # it is the login
          gate = false;
          # the root starts a login, which logs a line per probe
          health = "/ping";
        };
      };

      # ── checks ────────
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
    };
}
