# The gateway login (Authelia), for routed services that don't have their own.
# The user database is seeded once from the admin hash in secrets.json; after that
# Authelia owns it, so a changed hash in secrets.json doesn't apply any more.
{ lib, ... }:
let
  inherit (lib) filterAttrs mapAttrsToList;
in
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon) user cluster services;
      domain = cluster.domain;
      state = "/var/lib/authelia-main";

      policyOf = {
        "login" = "one_factor";
        "2fa" = "two_factor";
      };
      guarded = filterAttrs (
        _: service: service.route != null && !service.route.public && service.route.access != "open"
      ) services;
    in
    {
      sops.secrets = {
        "authelia/admin-hash" = { };
        "authelia/jwt".owner = "authelia-main";
        "authelia/session".owner = "authelia-main";
        "authelia/storage".owner = "authelia-main";
      };

      sops.templates."authelia-seed.yml".content = ''
        users:
          ${user.name}:
            disabled: false
            displayname: "${user.name}"
            password: "${config.sops.placeholder."authelia/admin-hash"}"
            email: ${user.email}
            groups:
              - admin
      '';

      systemd.services.authelia-main-seed = {
        description = "Seed the Authelia user database";
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
        '';
      };

      services.authelia.instances.main = {
        enable = true;
        secrets = {
          jwtSecretFile = config.sops.secrets."authelia/jwt".path;
          sessionSecretFile = config.sops.secrets."authelia/session".path;
          storageEncryptionKeyFile = config.sops.secrets."authelia/storage".path;
        };
        settings = {
          theme = "auto";
          server.address = "tcp://127.0.0.1:9091";
          authentication_backend.file.path = "${state}/users.yml";
          session.cookies = [
            {
              inherit domain;
              authelia_url = "https://auth.${domain}";
              default_redirection_url = "https://${domain}";
            }
          ];
          storage.local.path = "${state}/db.sqlite3";
          # password resets go to a file until mail is wired in
          notifier.filesystem.filename = "${state}/notifications.txt";
          access_control = {
            default_policy = "deny";
            rules = mapAttrsToList (_: service: {
              domain = "${service.route.subdomain}.${domain}";
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
          port = 9091;
          access = "open";
        };
        backup.paths = [ state ];
      };
    };
}
