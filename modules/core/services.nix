# Contract: axon.services. What a service offers the rest of the cluster.
# Declared in core so every module can publish unconditionally; on a host without a
# gateway or backup feature, nobody reads it and nothing happens.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  flake.modules.nixos.core = {
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

              volumes = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Names from cluster.toml [volumes] this service needs.";
              };
            };
          }
        )
      );
    };
  };
}
