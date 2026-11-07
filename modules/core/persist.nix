# Contract: axon.persist. Root is replaced on every boot; anything else that must
# survive is declared here, by the module that creates it, in the same file.
# /home is its own subvolume and is never rolled back.
# Machine state (network, keys, logs) stays on the boot disk. Service state, what features
# persist, goes to the host's state volume when it has one, so the boot disk holds only the
# system; without one it stays with the machine state.
{ inputs, lib, ... }:
let
  inherit (lib)
    mkOption
    optionalAttrs
    optionals
    types
    ;

  entry = types.either types.str (
    types.submodule {
      options = {
        directory = mkOption { type = types.str; };
        user = mkOption {
          type = types.str;
          default = "root";
        };
        group = mkOption {
          type = types.str;
          default = "root";
        };
        mode = mkOption {
          type = types.str;
          default = "0755";
        };
      };
    }
  );
in
{
  flake.modules.nixos.core =
    { config, pkgs, ... }:
    let
      cfg = config.axon.persist;
      device = config.fileSystems."/".device;
      state = config.axon.volumes.state or null;
    in
    {
      imports = [ inputs.impermanence.nixosModules.impermanence ];

      options.axon.persist = {
        directories = mkOption {
          type = types.listOf entry;
          default = [ ];
          description = "Directories that survive a reboot.";
        };
        files = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Files that survive a reboot.";
        };
        state.directories = mkOption {
          type = types.listOf entry;
          default = [ ];
          description = "A service's directories that survive a reboot: on the state volume when the host has one, with the rest otherwise.";
        };
      };

      config = {
        axon.persist = {
          directories = [
            "/var/lib/nixos"
            "/var/lib/systemd"
            "/var/log"
          ];
          files = [ "/etc/machine-id" ];
        };

        # the backend; swapping it for another one changes nothing else
        environment.persistence = {
          "/persist" = {
            hideMounts = true;
            inherit (cfg) files;
            directories = cfg.directories ++ optionals (state == null) cfg.state.directories;
          };
        }
        // optionalAttrs (state != null) {
          ${state} = {
            hideMounts = true;
            inherit (cfg.state) directories;
          };
        };

        # the backend wants its sources mounted early; a missing state disk (nofail) only leaves
        # its services without their state until it is back
        fileSystems = {
          "/persist".neededForBoot = true;
        }
        // optionalAttrs (state != null) {
          ${state}.neededForBoot = true;
        };

        # systemd starts DynamicUser services only under a 0700 /var/lib/private. Impermanence
        # copies every parent's mode from where it persists on each activation, so the copy there sets it.
        systemd.tmpfiles.rules = [
          "d /persist/var/lib/private 0700 root root -"
          "d /var/lib/private 0700 root root -"
        ]
        ++ optionals (state != null) [ "d ${state}/var/lib/private 0700 root root -" ];

        # the rollback below runs in the initrd, which has only the tools listed here
        boot.initrd.systemd.initrdBin = [
          pkgs.btrfs-progs
          pkgs.coreutils
          pkgs.findutils
          pkgs.util-linux
        ];

        boot.initrd.systemd.services.rollback = {
          description = "Replace the root subvolume with an empty one";
          wantedBy = [ "initrd.target" ];
          after = [ "initrd-root-device.target" ];
          before = [ "sysroot.mount" ];
          unitConfig.DefaultDependencies = "no";
          serviceConfig.Type = "oneshot";
          script = ''
            mkdir -p /btrfs
            mount -o subvol=/ ${device} /btrfs

            # keep the last roots for 30 days, for forensics and "what did I forget to persist"
            if [ -e /btrfs/root ]; then
              mkdir -p /btrfs/old_roots
              mv /btrfs/root "/btrfs/old_roots/$(date -r /btrfs/root +%F_%T)"
            fi
            find /btrfs/old_roots -mindepth 1 -maxdepth 1 -mtime +30 \
              -exec btrfs subvolume delete --recursive {} +

            btrfs subvolume create /btrfs/root
            umount /btrfs
          '';
        };
      };
    };
}
