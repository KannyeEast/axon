# Kanidm at auth.<domain>: the one login for every service that has one (axon.sso).
# Reach: public, its own login.
# In its UI only: people and their groups, backed up through its nightly online backup.
# By hand: make people and add them to family or admins with the kanidm CLI.
{ lib, ... }:
{
  flake.modules.nixos.gateway =
    { config, pkgs, ... }:
    let
      inherit (config.axon) domain sso;
      inherit (config.axon.services.auth.route) host url;
      inherit (config.services.kanidm.server.settings) online_backup;
      port = 8443;
      cert = "/var/lib/acme/${domain}";
      icons = pkgs.fetchFromGitHub {
        owner = "homarr-labs";
        repo = "dashboard-icons";
        rev = "f222c55843b888a82e9f2fe2697365841cbe6025";
        sparseCheckout = [ "svg" ];
        hash = "sha256-VcrGKm0smvXDKbs7hGLhoh+5doJd2gMXqTNMUivnQf4=";
      };
    in
    {
      # ── service ────────
      services.kanidm = {
        package = pkgs.kanidmWithSecretProvisioning_1_12;
        server = {
          enable = true;
          settings = {
            # the WebAuthn id every passkey is bound to: changing it breaks them all
            domain = host;
            origin = url;
            bindaddress = "127.0.0.1:${toString port}";
            tls_chain = "${cert}/fullchain.pem";
            tls_key = "${cert}/key.pem";
            # logs the client, not the proxy; a client can set the first address through the tunnel
            http_client_address_info.x-forward-for = [ "127.0.0.1" ];
            online_backup = {
              # beside the state, not in it: inside, the first switch creates it before the state's
              # mount, which then hides it, and kanidm's sandbox fails to start
              path = "/var/lib/kanidm-backups";
              # restic keeps the history
              versions = 1;
            };
          };
        };
        client = {
          enable = true;
          settings.uri = url;
        };
        provision = {
          enable = true;
          adminPasswordFile = config.sops.secrets."auth/admin-password".path;
          idmAdminPasswordFile = config.sops.secrets."auth/idm-admin-password".path;
          groups = lib.genAttrs [ "family" "admins" ] (_: {
            overwriteMembers = false;
          });
          systems.oauth2 = lib.mapAttrs (_: client: {
            inherit (client) displayName;
            originUrl = client.redirects;
            originLanding = client.landing;
            basicSecretFile = client.secret;
            imageFile = lib.mapNullable (icon: "${icons}/svg/${icon}") client.icon;
            preferShortUsername = true;
            scopeMaps.${client.group} = [
              "openid"
              "profile"
              "email"
              "groups"
            ];
          }) sso.clients;
        };
      };

      # this host's services reach Kanidm by name without DNS
      networking.hosts."127.0.0.1" = [ host ];

      # ── units ────────
      systemd.services.kanidm = {
        # the certificate exists, a placeholder at first, once acme-<domain> ran
        wants = [ "acme-${domain}.service" ];
        after = [ "acme-${domain}.service" ];
        # the certificate files belong to Caddy's group
        serviceConfig.SupplementaryGroups = [ config.services.caddy.group ];
      };
      # Kanidm reads its certificate only when it starts
      security.acme.certs.${domain}.reloadServices = [ "kanidm.service" ];

      # ── secrets ────────
      sops.secrets = {
        "auth/admin-password".owner = "kanidm";
        "auth/idm-admin-password".owner = "kanidm";
      }
      // lib.mapAttrs' (
        _: client:
        lib.nameValuePair client.key {
          owner = client.user;
          group = "kanidm";
          mode = "0440";
        }
      ) sso.clients;

      # ── data ────────
      axon.persist.state.directories =
        map
          (directory: {
            inherit directory;
            user = "kanidm";
            group = "kanidm";
            mode = "0700";
          })
          [
            "/var/lib/kanidm"
            online_backup.path
          ];

      # ── contracts ────────
      axon.sso.provider = {
        authorize = "${url}/ui/oauth2";
        token = "${url}/oauth2/token";
        userinfo = client: "${url}/oauth2/openid/${client}/userinfo";
        issuer = client: "${url}/oauth2/openid/${client}";
        # Kanidm lists groups as <name>@<its domain>
        group = group: "${group}@${host}";
        # provisioning runs in the unit's start, so clients exist once it's up
        unit = "kanidm.service";
      };

      # ── registration ────────
      axon.services.auth = {
        units = [ "kanidm" ];
        route = {
          inherit port;
          tls = true;
          public = true;
          # its login page logs every visit without a session as an error
          health = "/status";
        };
        dashboard = {
          name = "Kanidm";
          group = "Infrastructure";
          description = "Accounts and login";
          icon = "kanidm.svg";
        };
        backup.paths = [ online_backup.path ];
      };
    };
}
