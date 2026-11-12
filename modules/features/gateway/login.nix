# The gateway login (Authelia), for routed services that don't have their own.
# The user database is seeded once from the admin hash in secrets.json; after that
# Authelia owns it, so a changed hash in secrets.json doesn't apply any more.
# Its three keys (session cookies, database encryption, reset links) are random values
# nobody types, so the host makes them on first start and keeps them in the state folder,
# which is persisted and backed up: the database is unreadable without its key.
# Password resets and the like go through axon.mail to srv-info@, as that is the address its user
# is seeded with. Without an account they land in notifications.txt in the state folder.
{ lib, ... }:
let
  inherit (lib)
    filterAttrs
    mapAttrsToList
    mkIf
    optional
    toJSON
    ;
in
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon)
        user
        domain
        mail
        routes
        ;
      ph = config.sops.placeholder;
      port = 9091;
      state = "/var/lib/authelia-main";
      keys = "${state}/keys";
      email = if mail != null then mail.info else user.email;

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
            displayname: "${user.name}"
            password: "${ph."authelia/admin-hash"}"
            email: ${email}
            groups:
              - admin
      '';

      # merged over the settings below when Authelia starts
      sops.templates."authelia-mail.yml" = mkIf (mail != null) {
        owner = "authelia-main";
        content = toJSON {
          notifier.smtp = {
            address = "submission://${mail.host}:${toString mail.port}";
            username = mail.address;
            password = mail.token;
            sender = "Authelia <${mail.address}>";
          };
        };
        restartUnits = [ "authelia-main.service" ];
      };

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
        settingsFiles = optional (mail != null) config.sops.templates."authelia-mail.yml".path;
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
              authelia_url = routes.auth.route.url;
              default_redirection_url = routes.home.route.url;
            }
          ];
          storage.local.path = "${state}/db.sqlite3";
          # a mail outage must not keep the login from starting
          notifier =
            if mail != null then
              { disable_startup_check = true; }
            else
              { filesystem.filename = "${state}/notifications.txt"; };
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

      axon.persist.state.directories = [
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
