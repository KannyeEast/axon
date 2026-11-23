# Paperless-ngx at docs.<domain> on servers: scanned documents, OCR'd and filed. Tailnet only, its
# own login; without a gateway on this host it stays on localhost. The NixOS module, on the host's
# Postgres and its own Redis, with Tika and Gotenberg for Office files and mails. Documents on the data volume (or in the state folder without one).
# The nightly export (originals, OCR'd copies, tags and metadata) is what gets backed up; Paperless
# stops while it runs.
# First account by hand after install: sudo paperless-manage createsuperuser
# With a login provider (axon.sso) an account is linked to it once (My Profile → Connect new social
# account) and then logs in there; nobody signs up through it, and the password form stays.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, pkgs, ... }:
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
      # it pushes OpenTelemetry data to a collector on localhost by default and logs every failure
      systemd.services.gotenberg.environment = {
        OTEL_METRICS_EXPORTER = "none";
        OTEL_TRACES_EXPORTER = "none";
        OTEL_LOGS_EXPORTER = "none";
      };

      # at notice it logs each of its snapshots, every few minutes
      services.redis.servers.paperless.logLevel = "warning";

      # on a new space the empty folders tmpfiles made at boot give way to a subvolume; Paperless
      # won't start without them, so they are made again inside it
      systemd.services.storage-paperless.serviceConfig.ExecStartPost =
        "${lib.getExe' config.systemd.package "systemd-tmpfiles"} --create --prefix=${data}";

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
        # paperless-manage reads it as the paperless user
        owner = "paperless";
        # only the web server logs people in
        restartUnits = [ "paperless-web.service" ];
      };

      axon.sso.clients.paperless = {
        service = "docs";
        redirects = [ "${route.url}/accounts/oidc/${provider}/login/callback/" ];
      };

      axon.spaces.paperless = {
        user = "paperless";
        group = "paperless";
        units = [
          "paperless-consumer"
          "paperless-exporter"
          "paperless-scheduler"
          "paperless-task-queue"
          "paperless-web"
        ];
      };

      axon.databases = [ "paperless" ];

      # the search index as an entry of its own: the module's tmpfiles rule for it runs before the
      # dataDir's mount on a switch and ends up hidden under it, and the scheduler won't start without
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
          ]
        ++ [ "/var/lib/redis-paperless" ];

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
