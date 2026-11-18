# Paperless-ngx at docs.<domain> on servers: scanned documents, OCR'd and filed. Tailnet only, its
# own login; without a gateway on this host it stays on localhost. Upstream's container, run as
# the paperless user, on the host's Postgres and its own Redis through their sockets. Documents on
# the data volume (or in the state folder without one). The nightly export (originals, OCR'd
# copies, tags and metadata) is what gets backed up.
# First account by hand after install: sudo docker exec -it paperless createsuperuser
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
      state = "/var/lib/paperless";
      # where the NixOS module kept its generated key, so sessions survive; made when missing
      keyFile = "${state}/nixos-paperless-secret-key.env";
      redis = config.services.redis.servers.paperless.unixSocket;
      docker = lib.getExe' config.virtualisation.docker.package "docker";
      port = 28981;
      # the ids the NixOS module gave it; its files on disk belong to them
      id = 315;
      provider = "kanidm";

      prepare = pkgs.writeShellScript "paperless-prepare" ''
        for dir in media consume export; do
          [ -d ${data}/$dir ] || install -d -o paperless -g paperless ${data}/$dir
        done
        if [ ! -e ${keyFile} ]; then
          umask 0077
          printf 'PAPERLESS_SECRET_KEY=%s\n' "$(tr -dc A-Za-z0-9 </dev/urandom | head -c64)" >${keyFile}
          chown paperless:paperless ${keyFile}
        fi
      '';
    in
    lib.mkIf (config.axon.host.class == "server") {
      users.users.paperless = {
        isSystemUser = true;
        group = "paperless";
        uid = id;
      };
      users.groups.paperless.gid = id;

      services.postgresql = {
        enable = true;
        ensureDatabases = [ "paperless" ];
        ensureUsers = [
          {
            name = "paperless";
            ensureDBOwnership = true;
          }
        ];
      };

      # the socket's group, so the container reaches it
      services.redis.servers.paperless = {
        enable = true;
        group = "paperless";
      };

      virtualisation.oci-containers.containers.paperless = {
        image = "ghcr.io/paperless-ngx/paperless-ngx:3.4.2@sha256:d704e84f88300eb6ab001ab15720a2330ff99169cf9f94d6b8fcc44b63a84c84";
        user = "${toString id}:${toString id}";
        networks = [ "host" ];
        environment = {
          PAPERLESS_BIND_ADDR = "127.0.0.1";
          PAPERLESS_PORT = toString port;
          PAPERLESS_TIME_ZONE = config.axon.locale.timezone;
          PAPERLESS_REDIS = "unix://${redis}";
          PAPERLESS_DBENGINE = "postgresql";
          # peer login as the paperless user
          PAPERLESS_DBHOST = "/run/postgresql";
          PAPERLESS_DBNAME = "paperless";
          PAPERLESS_DBUSER = "paperless";
          # the image has German; PAPERLESS_OCR_LANGUAGES would install languages at start
          PAPERLESS_OCR_LANGUAGE = "deu+eng";
          PAPERLESS_FILENAME_FORMAT = "{{ correspondent }}/{{ created_year }}/{{ title }}";
        }
        // lib.optionalAttrs routed { PAPERLESS_URL = "https://${route.host}"; }
        // lib.optionalAttrs (sso.provider != null) {
          PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
          # a login the provider knows but no account here is linked to ends at "sign up closed"
          PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = "false";
        };
        environmentFiles = [
          keyFile
        ]
        ++ lib.optional (sso.provider != null) config.sops.templates."paperless.env".path;
        volumes = [
          "${state}:/usr/src/paperless/data"
          "${data}/media:/usr/src/paperless/media"
          "${data}/consume:/usr/src/paperless/consume"
          "${data}/export:/usr/src/paperless/export"
          "/run/postgresql:/run/postgresql"
          "${dirOf redis}:${dirOf redis}"
        ];
        # the image's check asks port 8000, which isn't the one it listens on here
        extraOptions = [ "--no-healthcheck" ];
      };

      systemd.services.docker-paperless = {
        # the socket folders are mounted, so these come first
        requires = [
          "postgresql.target"
          "redis-paperless.service"
        ];
        after = [
          "postgresql.target"
          "redis-paperless.service"
        ];
        # the mount sources, which Docker would make as root, and the secret key
        serviceConfig.ExecStartPre = [ "${prepare}" ];
      };

      # the container holds the socket folders it was started with; kept across a restart of their
      # service (a crash included), the new socket shows up in the same folder
      systemd.services.postgresql.serviceConfig.RuntimeDirectoryPreserve = "yes";
      systemd.services.redis-paperless.serviceConfig.RuntimeDirectoryPreserve = "yes";

      systemd.services.paperless-exporter = {
        description = "Export Paperless documents for the backup";
        requires = [ "docker-paperless.service" ];
        after = [ "docker-paperless.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${docker} exec paperless document_exporter /usr/src/paperless/export --no-progress-bar --no-color --compare-checksums --delete";
        };
      };
      systemd.timers.paperless-exporter = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "01:30";
      };

      sops.templates."paperless.env" = lib.mkIf (sso.provider != null) {
        # Docker's --env-file takes the value verbatim, quotes included
        content = ''
          PAPERLESS_SOCIALACCOUNT_PROVIDERS=${
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
          }
        '';
        restartUnits = [ "docker-paperless.service" ];
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
          "docker-paperless"
          "paperless-exporter"
        ];
      };

      axon.persist.state.directories = [
        {
          directory = state;
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
