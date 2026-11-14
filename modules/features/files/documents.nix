# Paperless-ngx at docs.<domain> on servers: scanned documents, OCR'd and filed. Tailnet only, its
# own login; without a gateway on this host it stays on localhost. Documents on the data volume
# (or in the state folder without one), database in the shared Postgres. The nightly export
# (originals, OCR'd copies, tags and metadata) is what gets backed up.
# First account by hand after install: sudo paperless-manage createsuperuser
# With a login provider (axon.sso) an account is linked to it once (My Profile → Connect new social
# account) and then logs in there; nobody signs up through it, and the password form stays.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, ... }:
    let
      inherit (config.axon) routed services sso;
      inherit (services.docs) route;
      client = sso.clients.paperless;
      data = config.axon.spaces.paperless.path;
      port = 28981;
      provider = "kanidm";
    in
    lib.mkIf (config.axon.host.class == "server") {
      services.paperless = {
        enable = true;
        inherit port;
        domain = if routed then route.host else null;
        mediaDir = "${data}/media";
        consumptionDir = "${data}/consume";
        database.createLocally = true;
        # every language: a shorter list rebuilds tesseract, ocrmypdf and paperless from source
        tesseractLanguages = null;
        settings = {
          PAPERLESS_OCR_LANGUAGE = "deu+eng";
          PAPERLESS_FILENAME_FORMAT = "{{ correspondent }}/{{ created_year }}/{{ title }}";
        }
        // lib.optionalAttrs (sso.provider != null) {
          PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
          # a login the provider knows but no account here is linked to ends at "sign up closed"
          PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = false;
        };
        environmentFile = lib.mkIf (sso.provider != null) config.sops.templates."paperless.env".path;
        exporter = {
          enable = true;
          directory = "${data}/export";
        };
      };

      sops.templates."paperless.env" = lib.mkIf (sso.provider != null) {
        # paperless-manage reads it as paperless
        owner = "paperless";
        # single quotes keep the JSON verbatim
        content = ''
          PAPERLESS_SOCIALACCOUNT_PROVIDERS='${
            lib.toJSON {
              openid_connect.APPS = [
                {
                  provider_id = provider;
                  name = "Kanidm";
                  client_id = client.id;
                  secret = config.sops.placeholder."sso/${client.id}";
                  settings = {
                    server_url = client.issuer;
                    # the provider requires it; allauth leaves it off
                    oauth_pkce_enabled = true;
                  };
                }
              ];
            }
          }'
        '';
        restartUnits = [ "paperless-web.service" ];
      };

      axon.sso.clients.paperless = {
        displayName = "Paperless";
        landing = route.url;
        redirects = [ "${route.url}/accounts/oidc/${provider}/login/callback/" ];
        inherit (services.docs.dashboard) icon;
      };

      axon.spaces.paperless = {
        user = "paperless";
        group = "paperless";
        units = [
          "paperless-consumer"
          "paperless-task-queue"
          "paperless-web"
          "paperless-exporter"
        ];
      };

      axon.persist.state.directories = [
        {
          directory = "/var/lib/paperless";
          user = "paperless";
          group = "paperless";
          mode = "0750";
        }
        "/var/lib/redis-paperless"
      ];

      axon.services.docs = {
        route.port = port;
        dashboard = {
          name = "Paperless";
          group = "Files";
          description = "Documents";
          icon = "paperless-ngx.svg";
          widget.type = "paperlessngx";
          key = true;
        };
        backup.paths = [ "${data}/export" ];
      };
    };
}
