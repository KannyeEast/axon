# Contract: axon.sso. Single sign-on: the login provider sets provider, and a service with a
# login registers a client here. The provider registers only its own host's clients; today all of
# them are on the gateway host. With provider null a service keeps just its own login.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon.sso) provider;
    in
    {
      options.axon.sso = {
        provider = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The login provider's base URL, set by the provider. Consumers must work with null.";
        };

        clients = mkOption {
          default = { };
          description = "Services that log users in at the provider, by client id.";
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  displayName = mkOption { type = types.str; };
                  landing = mkOption {
                    type = types.str;
                    description = "Where the provider's app list leads.";
                  };
                  redirects = mkOption {
                    type = types.listOf types.str;
                    description = "Redirect URLs the client may use, matched exactly.";
                  };
                  group = mkOption {
                    type = types.enum [
                      "family"
                      "admins"
                    ];
                    default = "family";
                    description = "The provider's group allowed in; admins for the owner's tools.";
                  };
                  icon = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "An svg from homarr-labs/dashboard-icons for the provider's app list, e.g. immich.svg.";
                  };
                  user = mkOption {
                    type = types.str;
                    default = name;
                    defaultText = "<name>";
                    description = "The service's user, which reads the client secret.";
                  };
                  id = mkOption {
                    type = types.str;
                    readOnly = true;
                    default = name;
                    defaultText = "<name>";
                  };
                  issuer = mkOption {
                    type = types.nullOr types.str;
                    readOnly = true;
                    default = if provider != null then "${provider}/oauth2/openid/${name}" else null;
                    defaultText = "<provider>/oauth2/openid/<name>, null without a provider";
                    description = "The client's OpenID Connect issuer; the provider has one per client.";
                  };
                  secret = mkOption {
                    type = types.str;
                    readOnly = true;
                    default = config.sops.secrets."sso/${name}".path;
                    defaultText = "the path of the sops secret sso/<name>";
                    description = "The client secret, from secrets.json; readable by the provider and user.";
                  };
                };
              }
            )
          );
        };
      };
    };
}
