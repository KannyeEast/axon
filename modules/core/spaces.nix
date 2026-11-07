# Contract: axon.spaces. A service's own space on a volume: on a host with that volume it is the
# btrfs subvolume <volume>/<name>, which host.toml [limits] can cap; without it, /var/lib/<name>.
# One unit per space creates it before the service's units start (they also wait for its disk);
# storage-limits applies [limits] to spaces and whole volumes, so a changed limit takes effect on
# the next switch, without moving data.
# A space that is still a plain folder holding files is left alone, with a warning in its unit's
# log; an empty one (made by a service's own tmpfiles rules) becomes a subvolume.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatMap
    concatMapStrings
    concatStringsSep
    filterAttrs
    genAttrs
    getExe'
    mapAttrs'
    mapAttrsToList
    mkMerge
    mkOption
    nameValuePair
    optionalAttrs
    types
    unique
    ;
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
      btrfs = getExe' pkgs.btrfs-progs "btrfs";

      onVolume = filterAttrs (_: space: space.onVolume) spaces;
      # what [limits] may name: whole volumes and the spaces on them
      limitable = attrNames volumes ++ attrNames onVolume;
      paths =
        genAttrs (attrNames volumes) (name: volumes.${name})
        // mapAttrs' (name: space: nameValuePair name space.path) onVolume;

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
              chown ${space.user}:${space.group} "$path"
              chmod ${space.mode} "$path"
            ''
          else
            ''
              install -d -m ${space.mode} -o ${space.user} -g ${space.group} ${space.path}
            ''
        );

      # quotas are switched on, per filesystem, only where something is limited: through the volume
      # it lives on, which is mounted even while a space doesn't exist yet
      limited = filterAttrs (name: _: paths ? ${name}) limits;
      volumeOf = name: volumes.${name} or volumes.${spaces.${name}.volume};
      applyLimits = pkgs.writeShellScript "storage-limits" ''
        set -u
        ${concatMapStrings (path: ''
          ${btrfs} quota enable ${path}
        '') (unique (map volumeOf (attrNames limited)))}
        for path in ${concatStringsSep " " (mapAttrsToList (_: path: path) paths)}; do
          [ "$(stat -c %i "$path" 2>/dev/null)" = 256 ] || continue
          ${btrfs} qgroup show "$path" >/dev/null 2>&1 || continue
          case "$path" in
          ${concatMapStrings (name: ''
            ${paths.${name}}) ${btrfs} qgroup limit ${limits.${name}} "$path" ;;
          '') (attrNames limited)}
            *) ${btrfs} qgroup limit none "$path" ;;
          esac
        done
      '';
    in
    {
      options.axon.spaces = mkOption {
        default = { };
        description = "Service name to its own space on a volume.";
        type = types.attrsOf (
          types.submodule (
            { name, config, ... }:
            {
              options = {
                volume = mkOption {
                  type = types.str;
                  default = "data";
                  description = "The volume it lives on when the host has it.";
                };
                user = mkOption { type = types.str; };
                group = mkOption { type = types.str; };
                mode = mkOption {
                  type = types.str;
                  default = "0750";
                };
                units = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "systemd services that use it: they start after it exists and wait for its disk.";
                };
                onVolume = mkOption {
                  type = types.bool;
                  readOnly = true;
                  default = volumes ? ${config.volume};
                };
                path = mkOption {
                  type = types.str;
                  readOnly = true;
                  default = "${volumes.${config.volume} or "/var/lib"}/${name}";
                };
              };
            }
          )
        );
      };

      config = {
        assertions = mapAttrsToList (name: _: {
          assertion = paths ? ${name};
          message = "hosts/${host.name}/host.toml: [limits] names ${name}, which is neither a volume nor a service's space on one (${concatStringsSep ", " limitable})";
        }) limits;

        systemd.services = mkMerge (
          [
            (mapAttrs' (
              name: space:
              nameValuePair (unitOf name) {
                description = "Space for ${name}";
                # the data disk may be missing at boot (nofail): never write to root instead
                unitConfig.RequiresMountsFor = [ space.path ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = make name space;
                };
              }
            ) spaces)
            (optionalAttrs (paths != { }) {
              storage-limits = {
                description = "Apply [limits] to volumes and spaces";
                wantedBy = [ "multi-user.target" ];
                after = map (name: "${unitOf name}.service") (attrNames onVolume);
                unitConfig.RequiresMountsFor = mapAttrsToList (_: path: path) paths;
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = applyLimits;
                };
              };
            })
          ]
          # every unit that uses a space starts after it exists and waits for its disk
          ++ concatMap (
            name:
            map (unit: {
              ${unit} = {
                requires = [ "${unitOf name}.service" ];
                after = [ "${unitOf name}.service" ];
                unitConfig.RequiresMountsFor = [ spaces.${name}.path ];
              };
            }) spaces.${name}.units
          ) (attrNames spaces)
        );
      };
    };
}
