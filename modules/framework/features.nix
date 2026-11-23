# The registry: every class and feature, and the host.toml tables each of them owns.
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
              description = "What it is for, in a line.";
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
              description = "What it is for, in a line.";
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
    # read by install.sh for its lists of classes, features and storage profiles
    flake.axon = {
      inherit (config.axon) classes features profiles;
    };
  };
}
