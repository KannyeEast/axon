# Contract: axon.spaces. A service's own space: the btrfs subvolume <data>/<name>, which [limits]
# can cap, or /var/lib/spaces/<name> on a host without a data volume. Its unit creates it before
# the services in `units` start.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  axon.schema.core = {
    options.limits = mkOption {
      type = types.attrsOf (types.strMatching "[0-9]+[KMGTP]?");
      default = { };
      example = {
        media = "5T";
        immich = "1T";
      };
      description = "Most a volume or a service's space may hold, e.g. 500G or 5T (powers of 1024); a name not listed has no limit. A volume's limit doesn't count the spaces on it.";
    };
  };

  flake.modules.nixos.core =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        host
        limits
        spaces
        volumes
        ;
      btrfs = lib.getExe' pkgs.btrfs-progs "btrfs";

      onVolume = lib.filterAttrs (_: space: space.onVolume) spaces;
      limitable = lib.attrNames volumes ++ lib.attrNames onVolume;
      paths = volumes // lib.mapAttrs' (name: space: lib.nameValuePair name space.path) onVolume;

      unitOf = name: "storage-${name}";

      make =
        name: space:
        pkgs.writeShellScript "storage-${name}" (
          if space.onVolume then
            ''
              path=${space.path}
              # a subvolume's top folder is always inode 256
              if [ -d "$path" ] && [ "$(stat -c %i "$path")" != 256 ]; then
                if [ -z "$(find "$path" ! -type d -print -quit)" ]; then
                  rm -r "$path"
                else
                  echo "$path: holds files but isn't a subvolume yet, so [limits] can't cap it; stop its service, move the folder aside, restart this unit and copy the files back" >&2
                fi
              fi
              [ -e "$path" ] || ${btrfs} subvolume create "$path"
              ${lib.optionalString (limits ? ${name}) ''
                # a switch runs storage-limits before a new space exists, so its limit is set here too
                ${btrfs} quota enable ${volumeOf name}
                ${btrfs} qgroup limit ${limits.${name}} "$path"
              ''}
              chown ${space.user}:${space.group} "$path"
              chmod 0750 "$path"
            ''
          else
            ''
              install -d -m 0750 -o ${space.user} -g ${space.group} ${space.path}
            ''
        );

      # quotas go on only where something is limited, through the volume: it exists before the space
      limited = lib.filterAttrs (name: _: paths ? ${name}) limits;
      volumeOf = name: volumes.${name} or volumes.data;
      applyLimits = pkgs.writeShellScript "storage-limits" ''
        set -u
        ${lib.concatMapStrings (path: ''
          ${btrfs} quota enable ${path}
        '') (lib.unique (map volumeOf (lib.attrNames limited)))}
        for path in ${lib.concatStringsSep " " (lib.attrValues paths)}; do
          [ "$(stat -c %i "$path" 2>/dev/null)" = 256 ] || continue
          ${btrfs} qgroup show "$path" >/dev/null 2>&1 || continue
          case "$path" in
          ${lib.concatMapStrings (name: ''
            ${paths.${name}}) ${btrfs} qgroup limit ${limits.${name}} "$path" ;;
          '') (lib.attrNames limited)}
            *) ${btrfs} qgroup limit none "$path" ;;
          esac
        done
      '';
    in
    {
      # ── contract ────────
      options.axon.spaces = mkOption {
        default = { };
        description = "Service name to its own space on a volume.";
        type = types.attrsOf (
          types.submodule (
            { name, ... }:
            {
              options = {
                user = mkOption {
                  type = types.str;
                  description = "Owner of the space.";
                };
                group = mkOption {
                  type = types.str;
                  description = "Group of the space.";
                };
                units = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "systemd services that use it: they start after it exists and wait for its disk.";
                };
                onVolume = mkOption {
                  type = types.bool;
                  readOnly = true;
                  default = volumes ? data;
                  defaultText = "whether the host has a data volume";
                  description = "Whether it is a subvolume on the data volume.";
                };
                path = mkOption {
                  type = types.str;
                  readOnly = true;
                  # not /var/lib/<name>: that is often the service's own state folder
                  default = "${volumes.data or "/var/lib/spaces"}/${name}";
                  defaultText = "<data volume>/<name>, else /var/lib/spaces/<name>";
                  description = "Where the space is.";
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
              name: space:
              lib.nameValuePair (unitOf name) {
                description = "Space for ${name}";
                # also for a space no unit lists, which then still exists after boot
                wantedBy = [ "multi-user.target" ];
                # the data disk may be missing at boot (nofail): never write to root instead
                unitConfig.RequiresMountsFor = [ space.path ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = make name space;
                };
              }
            ) spaces)
            (lib.optionalAttrs (paths != { }) {
              storage-limits = {
                description = "Apply [limits] to volumes and spaces";
                wantedBy = [ "multi-user.target" ];
                after = map (name: "${unitOf name}.service") (lib.attrNames onVolume);
                unitConfig.RequiresMountsFor = lib.attrValues paths;
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = applyLimits;
                };
              };
            })
          ]
          ++ lib.concatMap (
            name:
            map (unit: {
              ${unit} = {
                requires = [ "${unitOf name}.service" ];
                after = [ "${unitOf name}.service" ];
                unitConfig.RequiresMountsFor = [ spaces.${name}.path ];
              };
            }) spaces.${name}.units
          ) (lib.attrNames spaces)
        );

        # ── data ────────
        # a space on a volume persists with it; only the /var/lib fallback is listed
        axon.persist.state.directories = lib.mapAttrsToList (_: space: {
          directory = space.path;
          inherit (space) user group;
          mode = "0750";
        }) (lib.filterAttrs (_: space: !space.onVolume) spaces);

        # ── checks ────────
        assertions = lib.mapAttrsToList (name: _: {
          assertion = paths ? ${name};
          message = "hosts/${host.name}/host.toml: [limits] names ${name}, which is neither a volume nor a service's space on one (${lib.concatStringsSep ", " limitable})";
        }) limits;
      };
    };
}
