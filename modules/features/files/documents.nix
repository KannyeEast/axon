# Paperless-ngx at docs.<domain>: scanned documents, OCR'd and filed.
# Reach: tailnet, its own login; axon.sso's once an account is linked to it (My Profile).
# In its UI only: tags and metadata, backed up with the documents by the nightly export.
# By hand: `sudo paperless-manage createsuperuser`.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, pkgs, ... }:
    let
      inherit (config.axon) routed services sso;
      inherit (services.docs) route;
      port = 28981;
      provider = "kanidm";
      client = sso.clients.paperless;
      data = config.axon.spaces.paperless.path;
    in
    lib.mkIf (config.axon.host.class == "server") {
      # ── service ────────
      services.paperless = {
        enable = true;
        # the database was migrated by 3.5.1; an older package can't run on it
        package =
          if lib.versionOlder pkgs.paperless-ngx.version "3.5.1" then
            pkgs.paperless-ngx.overrideAttrs (
              finalAttrs: _: {
                version = "3.5.1";
                src = pkgs.fetchFromGitHub {
                  owner = "paperless-ngx";
                  repo = "paperless-ngx";
                  tag = "v${finalAttrs.version}";
                  hash = "sha256-sb3gg7Jla5OErT5iz6DP45IqfithmRMPTjqTiMwvHYw=";
                };
              }
            )
          else
            pkgs.paperless-ngx;
        inherit port;
        mediaDir = "${data}/media";
        consumptionDir = "${data}/consume";
        database.createLocally = true;
        configureTika = true;
        # the backup; Paperless stops while it runs
        exporter = {
          enable = true;
          directory = "${data}/export";
        };
        environmentFile = lib.mkIf (sso.provider != null) config.sops.templates."paperless.env".path;
        settings = {
          PAPERLESS_OCR_LANGUAGE = "deu+eng";
          PAPERLESS_FILENAME_FORMAT = "{{ correspondent }}/{{ created_year }}/{{ title }}";
        }
        // lib.optionalAttrs routed {
          PAPERLESS_URL = route.url;
          # with a URL it answers only that name and localhost; the start page asks by address
          PAPERLESS_ALLOWED_HOSTS = "127.0.0.1";
        }
        // lib.optionalAttrs (sso.provider != null) {
          PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
          # a login the provider knows but no account here is linked to ends at "sign up closed"
          PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = false;
        };
      };

      # its default 3000 is AdGuard's
      services.gotenberg.port = 3002;

      # ── units ────────
      # it pushes OpenTelemetry data to a collector on localhost by default and logs every failure
      systemd.services.gotenberg.environment = {
        OTEL_METRICS_EXPORTER = "none";
        OTEL_TRACES_EXPORTER = "none";
        OTEL_LOGS_EXPORTER = "none";
      };

      # tmpfiles may run before the space mounts (at boot, or on the switch that adds it) and leave
      # its folders hidden under it; Paperless won't start without them, so its first unit makes them
      systemd.services.paperless-scheduler.serviceConfig.ExecStartPre = lib.mkBefore [
        "+${lib.getExe' config.systemd.package "systemd-tmpfiles"} --create --prefix=${data}"
      ];

      # ── secrets ────────
      sops.templates."paperless.env" = lib.mkIf (sso.provider != null) {
        # in single quotes systemd and paperless-manage's shell both take the JSON verbatim
        content = ''
          PAPERLESS_SOCIALACCOUNT_PROVIDERS='${
            lib.toJSON {
              openid_connect.APPS = [
                {
                  provider_id = provider;
                  name = "Kanidm";
                  client_id = client.id;
                  secret = client.placeholder;
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
        # paperless-manage reads it as the paperless user
        owner = "paperless";
        # only the web server logs people in
        restartUnits = [ "paperless-web.service" ];
      };

      # ── login ────────
      axon.sso.clients.paperless = {
        service = "docs";
        redirects = [ "${route.url}/accounts/oidc/${provider}/login/callback/" ];
      };

      # ── data ────────
      axon.spaces.paperless = {
        user = "paperless";
        group = "paperless";
        mode = "0750";
        units = [
          "paperless-consumer"
          "paperless-exporter"
          "paperless-scheduler"
          "paperless-task-queue"
          "paperless-web"
        ];
      };

      axon.databases = [ "paperless" ];

      # the search index gets its own entry: the module's tmpfiles rule runs before the dataDir's
      # mount on a switch and is hidden under it, and the scheduler won't start without it
      axon.persist.state.directories =
        map
          (directory: {
            inherit directory;
            user = "paperless";
            group = "paperless";
            mode = "0750";
          })
          [
            config.services.paperless.dataDir
            "${config.services.paperless.dataDir}/index"
          ];

      # ── registration ────────
      axon.services.docs = {
        units = [
          "paperless-consumer"
          "paperless-exporter"
          "paperless-scheduler"
          "paperless-secret-key"
          "paperless-task-queue"
          "paperless-web"
          "gotenberg"
          "redis-paperless"
          "tika"
        ];
        route = {
          inherit port;
          gate = false;
        };
        dashboard = {
          name = "Paperless";
          group = "Files";
          description = "Documents";
          icon = "paperless-ngx.svg";
          space = "paperless";
          widget.type = "paperlessngx";
          key = true;
        };
        backup.paths = [ "${data}/export" ];
      };
    };
}
