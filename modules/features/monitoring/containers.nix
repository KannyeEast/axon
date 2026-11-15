# Komodo at komodo.<domain>, tailnet only: this host's containers, their logs and stats, and a
# terminal. Nix deploys every container; Komodo only shows them. Core and its database (FerretDB
# over Postgres) run as containers on the host's network, each listening on 127.0.0.1; the
# Periphery agent runs from nixpkgs and connects to Core. Core trusts the key Periphery made, read
# from Periphery's folder; Periphery keeps Core's from their first connection.
# With a login provider (axon.sso) its admins log in there, else with Komodo's own login. Only
# the first account to log in is made. Nothing is backed up: all it shows comes from Docker.
{ lib, ... }:
{
  flake.modules.nixos.monitoring =
    { config, ... }:
    let
      inherit (config.axon) host sso;
      inherit (config.axon.services.komodo) route;
      client = sso.clients.komodo;
      ph = config.sops.placeholder;
      periphery = config.services.komodo-periphery;
      port = 9120;
      # beside the host's own Postgres on 5432
      postgres = 5433;
      mongo = 27017;
      user = "komodo";
      state = "/var/lib/komodo";

      # Docker's --env-file takes every value verbatim, quotes included
      envFile = name: values: {
        content = lib.concatStrings (lib.mapAttrsToList (key: value: "${key}=${value}\n") values);
        restartUnits = [ "docker-${name}.service" ];
      };
      envFileOf = name: [ config.sops.templates."${name}.env".path ];
    in
    {
      virtualisation.oci-containers.containers = {
        komodo-db = {
          image = "ghcr.io/ferretdb/postgres-documentdb:17-0.107.0-ferretdb-2.7.0@sha256:2386795ec2aa7ae559304361979f1dc5708d383ee9020ae63dadc2940dfe58f7";
          networks = [ "host" ];
          environment = {
            POSTGRES_USER = user;
            # the database FerretDB keeps its data in
            POSTGRES_DB = "postgres";
            PGPORT = toString postgres;
          };
          environmentFiles = envFileOf "komodo-db";
          cmd = [
            "postgres"
            "-c"
            "listen_addresses=127.0.0.1"
          ];
          volumes = [ "${state}/postgres:/var/lib/postgresql/data" ];
          # Komodo's "stop all containers" leaves it running
          labels."komodo.skip" = "";
        };

        komodo-ferretdb = {
          image = "ghcr.io/ferretdb/ferretdb:2.7.0@sha256:5706414241eb84f0515512c37b46db0f1b1eac9e5ceb7e4c2523211c184b1985";
          networks = [ "host" ];
          dependsOn = [ "komodo-db" ];
          environment = {
            # FerretDB's own defaults, which the image widens to every address
            FERRETDB_LISTEN_ADDR = "127.0.0.1:${toString mongo}";
            FERRETDB_DEBUG_ADDR = "127.0.0.1:8088";
            DO_NOT_TRACK = "1";
          };
          environmentFiles = envFileOf "komodo-ferretdb";
          labels."komodo.skip" = "";
        };

        komodo-core = {
          image = "ghcr.io/moghtech/komodo-core:2.3.4@sha256:91b2afd7b3bb2abea0ebd3046d65ec457eb1f3d505868d1d60cb0f8562490ef9";
          networks = [ "host" ];
          dependsOn = [ "komodo-ferretdb" ];
          environment = {
            KOMODO_HOST = route.origin;
            KOMODO_BIND_IP = "127.0.0.1";
            KOMODO_PORT = toString port;
            KOMODO_DATABASE_ADDRESS = "127.0.0.1:${toString mongo}";
            KOMODO_DATABASE_USERNAME = user;
            KOMODO_FIRST_SERVER_NAME = host.name;
            KOMODO_PERIPHERY_PUBLIC_KEY = "file:/periphery/periphery.pub";
            KOMODO_DISABLE_USER_REGISTRATION = "true";
            # no procedures that update containers or back up the database: Nix does the one, and
            # nothing here needs the other
            KOMODO_DISABLE_INIT_RESOURCES = "true";
          }
          // lib.optionalAttrs (sso.provider == null) { KOMODO_LOCAL_AUTH = "true"; }
          // lib.optionalAttrs (sso.provider != null) {
            KOMODO_OIDC_ENABLED = "true";
            KOMODO_OIDC_PROVIDER = client.issuer;
            KOMODO_OIDC_CLIENT_ID = client.id;
          };
          environmentFiles = envFileOf "komodo-core";
          volumes = [
            "${state}/keys:/config/keys"
            "${periphery.rootDirectory}/keys:/periphery:ro"
          ];
          # reaps what Core starts, as Komodo's own compose file does
          extraOptions = [ "--init" ];
        };
      };

      sops.secrets."komodo/db-password" = { };
      sops.secrets."komodo/jwt-secret" = { };
      sops.templates = {
        "komodo-db.env" = envFile "komodo-db" { POSTGRES_PASSWORD = ph."komodo/db-password"; };
        "komodo-ferretdb.env" = envFile "komodo-ferretdb" {
          # the password goes into the URL as it is, so it holds letters and digits only
          FERRETDB_POSTGRESQL_URL = "postgres://${user}:${ph."komodo/db-password"}@127.0.0.1:${toString postgres}/postgres";
        };
        "komodo-core.env" = envFile "komodo-core" (
          {
            KOMODO_DATABASE_PASSWORD = ph."komodo/db-password";
            KOMODO_JWT_SECRET = ph."komodo/jwt-secret";
          }
          // lib.optionalAttrs (sso.provider != null) {
            KOMODO_OIDC_CLIENT_SECRET = ph."sso/${client.id}";
          }
        );
      };

      services.komodo-periphery = {
        enable = true;
        outbound = {
          coreAddress = "ws://127.0.0.1:${toString port}";
          connectAs = host.name;
        };
      };

      axon.sso.clients.komodo = {
        displayName = "Komodo";
        landing = route.url;
        redirects = [ "${route.url}/auth/oidc/callback" ];
        group = "admins";
        # there is no komodo user: the secret only goes into Core's environment file, read as root
        user = "root";
        inherit (config.axon.services.komodo.dashboard) icon;
      };

      axon.persist.state.directories = [
        {
          directory = state;
          mode = "0700";
        }
        {
          directory = periphery.rootDirectory;
          inherit (periphery) user group;
        }
      ];

      axon.services.komodo = {
        route.port = port;
        dashboard = {
          name = "Komodo";
          group = "Containers";
          description = "Containers";
          icon = "komodo.svg";
          widget = {
            type = "komodo";
            highlight = {
              stopped.numeric = {
                level = "warn";
                when = "gt";
                value = 0;
              };
              unhealthy.numeric = {
                level = "warn";
                when = "gt";
                value = 0;
              };
            };
          };
          secrets = {
            key = "dashboard/komodo/key";
            secret = "dashboard/komodo/secret";
          };
        };
      };
    };
}
