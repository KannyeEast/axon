# Contract: axon.spaces. A service's data, by name, at /server/<name> on every host: a subvolume on
# the data disk whose [disk.<label>] spaces lists it, capped by the limit given there, else a
# folder persisted on the boot disk. Features register the spaces they bring and list them in
# their registry entry; one registrant sets owner and mode, the others add units. A registrant that
# keeps its data elsewhere when no disk lists the space sets fallback = false and checks disk.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  inherit (config.axon) coreSpaces;
in
{
  options.axon.coreSpaces = mkOption {
    type = types.listOf types.str;
    readOnly = true;
    default = [ "appdata" ];
    description = "The spaces core brings to every host; install.sh offers them with the features' own.";
  };

  config.flake.modules.nixos.core =
    {
      config,
      pkgs,
      utils,
      ...
    }:
    let
      inherit (config.axon)
        host
        onDisk
        registry
        spacePath
        spaces
        ;
      storage = lib.filterAttrs (_: fs: fs.spaces != { }) (removeAttrs config.axon.disk [ "boot" ]);
      offered =
        coreSpaces ++ lib.concatMap (feature: registry.${feature}.spaces.${host.class}) host.features;

      # the spaces core places: on a data disk, or on the boot disk unless the registrant keeps them
      placed = lib.filterAttrs (_: space: space.disk != null || space.fallback) spaces;
      onBoot = lib.filterAttrs (_: space: space.disk == null && space.fallback) spaces;
      onData = lib.filterAttrs (_: space: space.disk != null) spaces;
      tmpfilesOf = space: "tmpfiles-${utils.escapeSystemdPath space.path}";
      on = label: lib.filterAttrs (_: space: space.disk == label) spaces;
      # each disk that lists a space
      listed = lib.zipAttrs (
        lib.mapAttrsToList (label: fs: lib.mapAttrs (_: _: label) fs.spaces) storage
      );

      device = label: "${utils.escapeSystemdPath "/dev/disk/by-label/${label}"}.device";
      # the initrd mounts what boot needs (appdata) before any unit runs
      mounts =
        label:
        map (space: "${utils.escapeSystemdPath space.path}.mount") (
          lib.filter (space: !(config.fileSystems.${space.path}.neededForBoot or false)) (
            lib.attrValues (on label)
          )
        );

      make =
        label:
        pkgs.writeShellApplication {
          name = "storage-${label}";
          runtimeInputs = [
            pkgs.btrfs-progs
            pkgs.coreutils
            pkgs.util-linux
          ];
          text = ''
            top=/run/storage/${label}
            mkdir -p "$top"
            mount -o subvolid=5 /dev/disk/by-label/${label} "$top"
            trap 'umount "$top"' EXIT
            # on for every data disk, so each space reports its use, limited or not
            btrfs quota enable "$top"
            size=$(df -B1 --output=size "$top" | tail -n 1 | tr -d ' ')
            failed=0

            # name user group mode limit
            space() {
              local path="$top/$1"
              if [ ! -e "$path" ]; then
                btrfs subvolume create "$path"
              # a subvolume's top folder is always inode 256
              elif [ "$(stat -c %i "$path")" != 256 ]; then
                echo "<3>${label}: $1 is a folder, not a subvolume, so it doesn't mount; move it aside, restart this unit and move its files into the new subvolume" >&2
                failed=1
                return 0
              fi
              chown "$2:$3" "$path"
              chmod "$4" "$path"
              case $5 in
                none) btrfs qgroup limit none "$path" ;;
                # a share of the filesystem as it is now, so it grows with the disks
                *%) btrfs qgroup limit "$((size * ''${5%"%"} / 100))" "$path" ;;
                *) btrfs qgroup limit "$5" "$path" ;;
              esac
            }

            ${lib.concatStrings (
              lib.mapAttrsToList (
                name: space:
                "space ${name} ${space.user} ${space.group} ${space.mode} ${lib.defaultTo "none" space.limit}\n"
              ) (on label)
            )}
            exit "$failed"
          '';
        };
    in
    {
      # ── contract ────────
      options.axon.spacePath = mkOption {
        type = types.functionTo types.str;
        readOnly = true;
        default = name: "/server/${name}";
        defaultText = "name: /server/<name>";
        description = "A space's name to its path, the same on every host and disk.";
      };

      options.axon.onDisk = mkOption {
        type = types.attrsOf types.str;
        readOnly = true;
        default = lib.concatMapAttrs (label: fs: lib.mapAttrs (_: _: label) fs.spaces) storage;
        defaultText = "the spaces of every [disk.<label>] table, to its label";
        description = "Each space a data disk lists, to that disk's label. Read from host.toml alone, so the gate around a definition of axon.spaces can read it where axon.spaces would recurse.";
      };

      options.axon.spaces = mkOption {
        default = { };
        description = "A service's data, by name: on the data disk that lists it, else on the boot disk.";
        type = types.attrsOf (
          types.submodule (
            { name, ... }:
            let
              label = onDisk.${name} or null;
              value = storage.${label}.spaces.${name};
            in
            {
              options = {
                user = mkOption {
                  type = types.str;
                  default = "root";
                  description = "Owner of the space.";
                };
                group = mkOption {
                  type = types.str;
                  default = "root";
                  description = "Group of the space.";
                };
                mode = mkOption {
                  type = types.strMatching "[0-7]{4}";
                  default = "0755";
                  description = "Mode of the space, e.g. 0750.";
                };
                units = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "systemd services that use it: they wait for its mount.";
                };
                fallback = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Whether it lives on the boot disk when no data disk lists it; false where the registrant then keeps the data elsewhere.";
                };
                disk = mkOption {
                  type = types.nullOr types.str;
                  readOnly = true;
                  default = label;
                  defaultText = "the label of the [disk.<label>] that lists it, else null";
                  description = "The data disk that holds it; null for the boot disk.";
                };
                path = mkOption {
                  type = types.str;
                  readOnly = true;
                  default = spacePath name;
                  defaultText = "/server/<name>";
                  description = "Where it is.";
                };
                limit = mkOption {
                  type = types.nullOr types.str;
                  readOnly = true;
                  default = if label == null || value == true then null else value;
                  defaultText = "its value in [disk.<label>] spaces, null for true or the boot disk";
                  description = "The most it may hold, a size or a share of its disk; null for no limit.";
                };
              };
            }
          )
        );
      };

      config = {
        # ── units ────────
        systemd.services = lib.mkMerge (
          [
            (lib.mapAttrs' (
              label: _:
              lib.nameValuePair "storage-${label}" {
                description = "Spaces on the ${label} disk";
                # a mount only wants it, so a switch that restarts it leaves the mounts alone; a
                # space it couldn't make fails to mount by itself
                wantedBy = [ "multi-user.target" ] ++ mounts label;
                # early, so the mounts come as soon as the disk does, before most of the boot
                unitConfig.DefaultDependencies = false;
                conflicts = [ "shutdown.target" ];
                before = mounts label ++ [ "shutdown.target" ];
                requires = [ (device label) ];
                # the owners must exist: hosts that make users by a unit make them there
                after = [
                  (device label)
                  "systemd-sysusers.service"
                  "userborn.service"
                ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = lib.getExe (make label);
                };
              }
            ) storage)
          ]
          # tmpfiles-setup runs before nofail mounts, and waiting for them would hold the boot: the
          # rules under a space on a data disk run again once it is mounted
          ++ lib.mapAttrsToList (_: space: {
            ${tmpfilesOf space} = {
              description = "tmpfiles rules under ${space.path}";
              wantedBy = [ "multi-user.target" ];
              unitConfig.RequiresMountsFor = [ space.path ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${config.systemd.package}/bin/systemd-tmpfiles --create --prefix=${space.path}";
              };
            };
          }) onData
          # data disks mount with nofail: never write to root instead
          ++ lib.mapAttrsToList (
            _: space:
            lib.genAttrs space.units (
              _:
              {
                unitConfig.RequiresMountsFor = [ space.path ];
              }
              // lib.optionalAttrs (space.disk != null) {
                wants = [ "${tmpfilesOf space}.service" ];
                after = [ "${tmpfilesOf space}.service" ];
              }
            )
          ) placed
        );

        # ── data ────────
        axon.persist.directories = lib.mapAttrsToList (_: space: {
          directory = space.path;
          inherit (space) user group mode;
        }) onBoot;

        # ── checks ────────
        assertions =
          lib.mapAttrsToList (name: label: {
            assertion = spaces ? ${name};
            message = "hosts/${host.name}/host.toml: disk.${label} lists ${name}, which nothing on this host brings (${lib.concatStringsSep ", " (lib.attrNames spaces)})";
          }) onDisk
          ++ lib.mapAttrsToList (name: labels: {
            assertion = lib.length labels == 1;
            message = "hosts/${host.name}/host.toml: ${name} is on disk.${lib.concatStringsSep " and disk." labels}; a space lives on one disk";
          }) listed
          ++ map (name: {
            assertion = lib.elem name offered;
            message = "axon.spaces.${name}: not in the registry entry (spaces.${host.class}) of a feature this host lists, so install.sh doesn't offer it";
          }) (lib.attrNames spaces);
      };
    };
}
