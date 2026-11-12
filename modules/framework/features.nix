# The registry: every class and feature the framework knows about, and the pieces of
# host.toml each of them owns. hosts.nix, the docs and the installer all read these.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.axon = {
    classes = mkOption {
      default = { };
      description = "Main purpose of a host. Registered via modules/classes/<name>/class.nix";
      type = types.attrsOf (
        types.submodule {
          options = {
            description = mkOption {
              type = types.str;
            };
          };
        }
      );
    };

    features = mkOption {
      default = { };
      description = "Opt-in features. Registered via modules/features/<name>/feature.nix";
      type = types.attrsOf (
        types.submodule {
          options = {
            description = mkOption {
              type = types.str;
            };
            classes = mkOption {
              type = types.nonEmptyListOf (types.enum (lib.attrNames config.axon.classes));
              description = "Classes this feature can run on";
            };
            requires = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Features that must also be listed on the host";
            };
          };
        }
      );
    };

    # host.toml is checked against core's piece plus the pieces of the host's class and features,
    # so a table belonging to a feature the host doesn't list is an error
    schema = mkOption {
      type = types.attrsOf types.deferredModule;
      default = { };
      description = "Per bundle: the host.toml tables it owns, as module options.";
    };

    clusterSchema = mkOption {
      type = types.deferredModule;
      default = { };
      description = "cluster.toml, as module options.";
    };
  };

  config = {
    # the installer asks the flake what exists instead of keeping its own list
    flake.axon = {
      inherit (config.axon) classes features;
    };
  };
}
