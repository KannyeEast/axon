# Contract: axon.sso. Single sign-on: the login provider sets provider, and a service with a
# login registers a client here. The provider registers only its own host's clients; with
# provider null a service keeps just its own login.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) services;
      inherit (config.axon.sso) provider;
    in
    {
      options.axon.sso = {
        provider = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The login provider's base URL, set by the provider. Consumers must work with null.";
        };

        unit = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The provider's systemd unit on this host, started once its clients exist; for consumers that reach it while starting.";
        };

        clients = mkOption {
          default = { };
          description = "Services that log users in at the provider, by client id.";
          type = types.attrsOf (
            types.submodule (
              { name, ... }@client:
              let
                inherit (client.config) service;
                entry = services.${service};
                tile =
                  if entry.dashboard != null then
                    entry.dashboard
                  else
                    throw "axon.sso.clients.${name}: service ${service} has no dashboard; set displayName";
              in
              {
                options = {
                  service = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "The axon.services entry the client logs users in for; its tile's name and icon and its url are the defaults of displayName, icon and landing.";
                  };
                  displayName = mkOption {
                    type = types.str;
                    default =
                      if service != null then tile.name else throw "axon.sso.clients.${name}: set displayName or service";
                    defaultText = "the service's dashboard.name";
                    description = "The client's name in the provider's app list.";
                  };
                  landing = mkOption {
                    type = types.str;
                    default =
                      if service == null then
                        throw "axon.sso.clients.${name}: set landing or service"
                      else if entry.route != null then
                        entry.route.url
                      else
                        throw "axon.sso.clients.${name}: service ${service} has no route; set landing";
                    defaultText = "the service's route.url";
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
                    default = if service != null && entry.dashboard != null then entry.dashboard.icon else null;
                    defaultText = "the service's dashboard.icon, else null";
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
                    description = "The client's id at the provider.";
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
