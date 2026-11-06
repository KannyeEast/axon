# Contract: axon.services. What a service offers the rest of the cluster.
# Declared in core so every module can publish unconditionally; on a host without a
# gateway or backup feature, nobody reads it. Only a server warns, as its routes then
# reach no other machine.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatStringsSep
    filterAttrs
    mkOption
    optional
    types
    ;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) host routed services;
      routes = attrNames (filterAttrs (_: service: service.route != null) services);
    in
    {
      options.axon.routed = mkOption {
        type = types.bool;
        default = false;
        description = "Set by the gateway: this host serves the routes in axon.services. Consumers fall back when it doesn't.";
      };

      options.axon.services = mkOption {
        default = { };
        description = "One producer per entry, any number of consumers. Consumers must work with an empty set.";
        type = types.attrsOf (
          types.submodule (
            { name, ... }:
            {
              options = {
                route = mkOption {
                  default = null;
                  description = "Publish through the gateway as <subdomain>.<cluster domain>.";
                  type = types.nullOr (
                    types.submodule {
                      options = {
                        port = mkOption { type = types.port; };
                        address = mkOption {
                          type = types.str;
                          default = "127.0.0.1";
                        };
                        subdomain = mkOption {
                          type = types.str;
                          default = name;
                        };
                        access = mkOption {
                          type = types.enum [
                            "open" # no gateway login: public, or the service authenticates itself
                            "login" # gateway login
                            "2fa" # gateway login with a second factor
                          ];
                          default = "login";
                        };
                        public = mkOption {
                          type = types.bool;
                          default = false;
                          description = "Also reachable from the internet through the gateway's tunnel; on the tailnet either way. Only for services with their own login.";
                        };
                      };
                    }
                  );
                };

                dashboard = mkOption {
                  default = null;
                  description = "A tile on the gateway's start page, linked to the route.";
                  type = types.nullOr (
                    types.submodule {
                      options = {
                        name = mkOption { type = types.str; };
                        group = mkOption { type = types.str; };
                        description = mkOption {
                          type = types.str;
                          default = "";
                        };
                        icon = mkOption {
                          type = types.str;
                          description = "A name from homarr-labs/dashboard-icons, e.g. jellyfin.svg.";
                        };
                        monitor = mkOption {
                          type = types.str;
                          default = "/";
                          description = "Path the status dot requests; it follows redirects, so it must not lead off plain http.";
                        };
                        widget = mkOption {
                          type = types.nullOr (types.attrsOf types.anything);
                          default = null;
                          description = "Homepage widget settings; url defaults to the route's address.";
                        };
                        secrets = mkOption {
                          type = types.attrsOf types.str;
                          default = { };
                          example = {
                            key = "dashboard/radarr/key";
                          };
                          description = "Widget field -> key in the gateway host's secrets.json that holds its value.";
                        };
                        instances = mkOption {
                          default = { };
                          description = "One tile per entry instead of one, named by the key.";
                          type = types.attrsOf (
                            types.submodule {
                              options = {
                                widget = mkOption {
                                  type = types.attrsOf types.anything;
                                  default = { };
                                  description = "Merged over the service's widget.";
                                };
                                link = mkOption {
                                  type = types.nullOr types.str;
                                  default = null;
                                  description = "Where the tile leads instead of the route.";
                                };
                                icon = mkOption {
                                  type = types.nullOr types.str;
                                  default = null;
                                };
                                description = mkOption {
                                  type = types.nullOr types.str;
                                  default = null;
                                };
                              };
                            }
                          );
                        };
                      };
                    }
                  );
                };

                backup = {
                  paths = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Backed up by the backup feature. Empty means not backed up.";
                  };
                  exclude = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                  };
                };
              };
            }
          )
        );
      };

      config.warnings =
        optional (host.class == "server" && !routed && routes != [ ])
          "hosts/${host.name}/host.toml: ${concatStringsSep ", " routes} have routes but this host runs no gateway, so other machines can't reach them; list the gateway feature here or use ssh -L";
    };
}
