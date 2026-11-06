# The gateway login (Authelia), for routed services that don't have their own.
# The user database is seeded once from the admin hash in secrets.json; after that
# Authelia owns it, so a changed hash in secrets.json doesn't apply any more.
# Its three keys (session cookies, database encryption, reset links) are random values
# nobody types, so the host makes them on first start and keeps them in the state folder,
# which is persisted and backed up: the database is unreadable without its key.
{ lib, ... }:
let
  inherit (lib) filterAttrs mapAttrsToList;
in
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon)
        user
        domain
        routes
        services
        ;
      ph = config.sops.placeholder;
      port = 9091;
      state = "/var/lib/authelia-main";
      keys = "${state}/keys";

      policyOf = {
        "login" = "one_factor";
        "2fa" = "two_factor";
      };
      guarded = filterAttrs (_: service: service.route.access != "open") routes;
    in
    {
      sops.secrets."authelia/admin-hash" = { };

      sops.templates."authelia-seed.yml".content = ''
        users:
          ${user.name}:
            disabled: false
            displayname: "${user.name}"
            password: "${ph."authelia/admin-hash"}"
            email: ${user.email}
            groups:
              - admin
      '';

      systemd.services.authelia-main-seed = {
        description = "Seed the Authelia user database and create its keys";
        wantedBy = [ "multi-user.target" ];
        before = [ "authelia-main.service" ];
        requiredBy = [ "authelia-main.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "authelia-main";
          Group = "authelia-main";
          StateDirectory = "authelia-main";
          StateDirectoryMode = "0700";
          LoadCredential = "seed:${config.sops.templates."authelia-seed.yml".path}";
        };
        script = ''
          if [ ! -e ${state}/users.yml ]; then
            install -m 0600 "$CREDENTIALS_DIRECTORY/seed" ${state}/users.yml
          fi
          umask 077
          mkdir -p ${keys}
          for key in jwt session storage; do
            [ -e ${keys}/$key ] || head -c 48 /dev/urandom | base64 -w0 >${keys}/$key
          done
        '';
      };

      services.authelia.instances.main = {
        enable = true;
        secrets = {
          jwtSecretFile = "${keys}/jwt";
          sessionSecretFile = "${keys}/session";
          storageEncryptionKeyFile = "${keys}/storage";
        };
        settings = {
          theme = "auto";
          server.address = "tcp://127.0.0.1:${toString port}";
          authentication_backend.file.path = "${state}/users.yml";
          # the guarded services are tailnet-only, so a login may last: idle a day, at most a week
          session.inactivity = "1d";
          session.expiration = "1w";
          session.cookies = [
            {
              inherit domain;
              authelia_url = services.auth.route.url;
              default_redirection_url = "https://${domain}";
            }
          ];
          storage.local.path = "${state}/db.sqlite3";
          # password resets go to a file until mail is wired in
          notifier.filesystem.filename = "${state}/notifications.txt";
          access_control = {
            default_policy = "deny";
            rules = mapAttrsToList (_: service: {
              domain = service.route.host;
              policy = policyOf.${service.route.access};
              subject = [ "group:admin" ];
            }) guarded;
          };
        };
      };

      axon.persist.directories = [
        {
          directory = state;
          user = "authelia-main";
          group = "authelia-main";
          mode = "0700";
        }
      ];

      axon.services.auth = {
        route = {
          inherit port;
          access = "open";
        };
        dashboard = {
          name = "Authelia";
          group = "Network";
          description = "Login for the gateway";
          icon = "authelia.svg";
        };
        backup.paths = [ state ];
      };
    };
}
