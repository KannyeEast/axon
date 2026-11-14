# Kanidm at auth.<domain>: the one login for every service that has one (axon.sso). It provisions
# the groups family and admins and a client per axon.sso.clients entry of this host, its secret
# from secrets.json as sso/<client>. People and their groups are made by hand with the kanidm
# CLI and never appear here. It serves only HTTPS, with the gateway's certificate; what is backed
# up is its nightly online backup, not the live database.
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
      axon.sso.provider = url;

      sops.secrets = {
        "kanidm/admin-password".owner = "kanidm";
        "kanidm/idm-admin-password".owner = "kanidm";
      }
      // lib.mapAttrs' (
        name: client:
        lib.nameValuePair "sso/${name}" {
          owner = client.user;
          group = "kanidm";
          mode = "0440";
        }
      ) sso.clients;

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
            # restic keeps the history
            online_backup.versions = 1;
          };
        };
        client = {
          enable = true;
          settings.uri = url;
        };
        provision = {
          enable = true;
          adminPasswordFile = config.sops.secrets."kanidm/admin-password".path;
          idmAdminPasswordFile = config.sops.secrets."kanidm/idm-admin-password".path;
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

      systemd.services.kanidm = {
        # the certificate exists, a placeholder at first, once acme-<domain> ran
        wants = [ "acme-${domain}.service" ];
        after = [ "acme-${domain}.service" ];
        # the certificate files belong to Caddy's group (proxy.nix)
        serviceConfig.SupplementaryGroups = [ config.services.caddy.group ];
      };
      # Kanidm reads its certificate only when it starts
      security.acme.certs.${domain}.reloadServices = [ "kanidm.service" ];

      axon.persist.state.directories = [
        {
          directory = "/var/lib/kanidm";
          user = "kanidm";
          group = "kanidm";
          mode = "0700";
        }
      ];

      axon.services.auth = {
        route = {
          inherit port;
          tls = true;
          public = true;
        };
        dashboard = {
          name = "Kanidm";
          group = "Network";
          description = "Accounts and login";
          icon = "kanidm.svg";
        };
        backup.paths = [ online_backup.path ];
      };
    };
}
