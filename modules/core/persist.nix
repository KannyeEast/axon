# Contract: axon.persist. What survives the root wiped on every boot, declared by the module that
# creates it: machine state on the boot disk, service state on the state volume where there is one.
# /home is its own subvolume, never rolled back.
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
      state = config.axon.volumes.state or null;
    in
    {
      imports = [ inputs.impermanence.nixosModules.impermanence ];

      # ── contract ────────
      options.axon.persist = {
        directories = mkOption {
          type = types.listOf entry;
          default = [ ];
          description = "Directories that survive a reboot.";
        };
        state.directories = mkOption {
          type = types.listOf entry;
          default = [ ];
          description = "A service's directories that survive a reboot: on the state volume when the host has one, with the rest otherwise.";
        };
      };

      config = {
        # ── settings ────────
        # the journal stays small on the boot disk; with a monitoring host Loki keeps 30 days
        services.journald.settings.Journal.SystemMaxUse = "1G";

        environment.persistence = {
          "/persist" = {
            hideMounts = true;
            files = [ "/etc/machine-id" ];
            directories = cfg.directories ++ lib.optionals (state == null) cfg.state.directories;
          };
        }
        // lib.optionalAttrs (state != null) {
          ${state} = {
            hideMounts = true;
            directories = cfg.state.directories;
          };
        };

        # impermanence needs these in the initrd; a missing state disk (nofail) only costs its services their state
        fileSystems = {
          "/persist".neededForBoot = true;
        }
        // lib.optionalAttrs (state != null) {
          ${state}.neededForBoot = true;
        };

        # ── units ────────
        # systemd starts DynamicUser services only under a 0700 /var/lib/private; impermanence
        # copies each parent's mode from its persisted copy on every activation, so that copy sets it
        systemd.tmpfiles.rules = [
          "d /persist/var/lib/private 0700 root root -"
        ]
        ++ lib.optionals (state != null) [ "d ${state}/var/lib/private 0700 root root -" ];

        # find prunes old roots in the rollback; btrfs, coreutils and mount are in the initrd
        boot.initrd.systemd.initrdBin = [ pkgs.findutils ];

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

        # ── data ────────
        axon.persist.directories = [
          "/var/lib/nixos"
          "/var/lib/systemd"
          "/var/log"
        ];
      };
    };
}
