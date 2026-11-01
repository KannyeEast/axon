# Contract: axon.persist. Root is replaced on every boot; anything else that must
# survive is declared here, by the module that creates it, in the same file.
# /home is its own subvolume and is never rolled back.
{ inputs, lib, ... }:
let
  inherit (lib) mkOption types;

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
        environment.persistence."/persist" = {
          hideMounts = true;
          inherit (cfg) directories files;
        };

        fileSystems."/persist".neededForBoot = true;

        # persisting /var/lib/private/<name> makes the parent 0755, and systemd refuses to start
        # DynamicUser services under anything but 0700
        systemd.tmpfiles.rules = [ "d /var/lib/private 0700 root root -" ];

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
