# The schema of host.toml and cluster.toml. hosts.nix checks every host's file against these
# options (plus its class's and features' pieces) before NixOS evaluates, so a mistake points at
# the file.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  inherit (config.axon) classes features;

  # disk.boot: the framework owns its layout, the host picks the device and two sizes
  bootDisk = {
    options = {
      devices = mkOption {
        type = types.nonEmptyListOf types.str;
        description = "The boot disk, preferably by id. Exactly one. Wiped at install.";
      };
      swap = mkOption {
        type = types.ints.unsigned;
        default = 8;
        description = "Swap in GiB. RAM + 2 allows hibernation; 0 means none.";
      };
      reserve = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "GiB left unallocated at the end of the disk, for another OS.";
      };
    };
  };

  # disk.<name>: one btrfs filesystem, on one disk or as an array, labelled <name>
  extraDisk = {
    options = {
      devices = mkOption {
        type = types.nonEmptyListOf types.str;
        description = "Disks by id. The first one carries the filesystem; never wiped.";
      };
      profile = mkOption {
        type = types.enum [
          "single"
          "raid0"
          "raid1"
          "raid1c3"
          "raid1c4"
          "raid10"
          "raid5"
          "raid6"
        ];
        default = "single";
        description = "btrfs data profile. Metadata is kept off parity profiles.";
      };
      mounts = mkOption {
        type = types.attrsOf types.str;
        description = "Subvolume name to mountpoint. Features ask for a volume by this name.";
      };
    };
  };
in
{
  axon.schema.core =
    { config, ... }:
    {
      options = {
        host = {
          name = mkOption {
            type = types.str;
            readOnly = true;
            description = "The directory name under hosts/. Set by the framework.";
          };
          dir = mkOption {
            type = types.path;
            readOnly = true;
            internal = true;
            description = "hosts/<name> inside the flake source, for files read at evaluation.";
          };
          class = mkOption {
            type = types.enum (lib.attrNames classes);
            description = "What kind of machine this is.";
          };
          features = mkOption {
            type = types.listOf (types.enum (lib.attrNames features));
            default = [ ];
            description = "Opt-in features, by directory name under modules/features.";
          };
          state = mkOption {
            type = types.strMatching "[0-9]{2}\\.[0-9]{2}";
            description = "NixOS release the host was installed with. Written once, never changed.";
          };
          key = mkOption {
            type = types.str;
            description = "SSH host public key. Written once by the installer.";
          };
        };

        user = {
          name = mkOption {
            type = types.strMatching "[a-z_][a-z0-9_-]*";
            description = "Login name of the one person who uses this host.";
          };
          email = mkOption {
            type = types.str;
            description = "Git identity and certificate contact.";
          };
          key = mkOption {
            type = types.str;
            description = "SSH public key: login to other hosts and commit signing.";
          };
        };

        hardware.quirks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "nixos-hardware module names, for model-specific fixes facter can't detect.";
        };

        locale = {
          timezone = mkOption {
            type = types.str;
            default = "UTC";
            description = "Time zone, e.g. Europe/Berlin.";
          };
          language = mkOption {
            type = types.str;
            default = "en_US.UTF-8";
            description = "Locale for messages and the system language.";
          };
          formats = mkOption {
            type = types.str;
            default = config.locale.language;
            defaultText = "locale.language";
            description = "Locale for dates, numbers and units.";
          };
          keyboard = mkOption {
            type = types.str;
            default = "us";
            description = "xkb layout, used on the console and the desktop.";
          };
          variant = mkOption {
            type = types.str;
            default = "";
            description = "xkb variant of the layout, e.g. nodeadkeys; empty for the plain layout.";
          };
        };

        disk = mkOption {
          description = "disk.boot is the system disk; every other disk.<name> is a btrfs filesystem labelled <name>.";
          type = types.submodule {
            freeformType = types.attrsOf (types.submodule extraDisk);
            options.boot = mkOption {
              type = types.submodule bootDisk;
              description = "The system disk: ESP, swap and the root/nix/persist/home subvolumes.";
            };
          };
        };
      };
    };

  axon.clusterSchema = {
    options = {
      domain = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Services are published as <service>.<domain>.";
      };
      ssh = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
        description = "Member to the hosts its user key may log in to.";
      };
      sync = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
        description = "Folder to the members that share it with each other.";
      };
      external = mkOption {
        default = { };
        description = "Members that take part in relations but are not built from this repository.";
        type = types.attrsOf (
          types.submodule {
            options = {
              key = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "User SSH public key, for [ssh].";
              };
              sync = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Syncthing device id, for [sync].";
              };
            };
          }
        );
      };
      repo = {
        remotes = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Remote name to git URL for this repository; `just remotes` sets them up.";
        };
        origin = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The remote that is origin: pulled from and pushed to. The others are mirrors that origin pushes the reviewed branches to.";
        };
      };
    };
  };

  flake.modules.nixos.core =
    { config, ... }:
    {
      options.axon.home = mkOption {
        type = types.str;
        readOnly = true;
        default = config.users.users.${config.axon.user.name}.home;
        defaultText = "the home folder of user.name";
        description = "The user's home folder.";
      };

      options.axon.repo = mkOption {
        type = types.str;
        readOnly = true;
        default = "${config.axon.home}/axon";
        defaultText = "<home>/axon";
        description = "Where the checkout lives on the machine. Convention, not configuration.";
      };
    };
}
