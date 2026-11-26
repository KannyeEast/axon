# The disks. The boot disk's layout is fixed because persist.nix depends on it: a root subvolume
# replaced every boot, next to nix, persist and home. Every other [disk.<label>] is one btrfs
# filesystem, never wiped, with a subvolume per space it lists, mounted at the space's path.
{ inputs, lib, ... }:
let
  inherit (lib) mkOption types;

  subvolume = mountpoint: {
    inherit mountpoint;
    mountOptions = [
      "compress=zstd"
      "noatime"
    ];
  };

  # the fewest devices that make the profile worth having; mkfs.btrfs accepts fewer
  minimum = {
    single = 1;
    raid0 = 2;
    raid1 = 2;
    raid1c3 = 3;
    raid1c4 = 4;
    raid10 = 4;
    raid5 = 3;
    raid6 = 4;
  };

  # metadata as safe as the data: mkfs's default covers single and raid0, raid5/6 get a mirror
  metadataFor =
    profile:
    if profile == "raid5" || profile == "raid6" then
      "raid1c3"
    else if profile == "single" || profile == "raid0" then
      null
    else
      profile;

  mountOptions = [
    # bulk data (media) barely shrinks, so level 1 keeps writes fast; the boot disk uses the default
    "compress=zstd:1"
    "noatime"
    "nofail" # a missing data disk must not stop the boot
    "x-systemd.device-timeout=10s"
  ];
in
{
  options.axon.profiles = mkOption {
    type = types.attrsOf types.ints.positive;
    readOnly = true;
    default = minimum;
    description = "btrfs data profiles, each with the fewest devices that make it worth having.";
  };

  config.flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) host spacePath;
      boot = config.axon.disk.boot;
      storage = removeAttrs config.axon.disk [ "boot" ];

      # disko has no multi-device type: the first device carries the filesystem and names the
      # others for mkfs.btrfs; the others get an empty table
      disks =
        label: fs:
        let
          members = lib.tail fs.devices;
        in
        {
          ${label} = {
            type = "disk";
            device = lib.head fs.devices;
            destroy = false; # only the boot disk is ever wiped
            content = {
              type = "btrfs";
              extraArgs = [
                "-f"
                "-L"
                label
                "-d"
                fs.profile
              ]
              ++ lib.optionals (metadataFor fs.profile != null) [
                "-m"
                (metadataFor fs.profile)
              ]
              ++ members;
              subvolumes = lib.mapAttrs (name: _: {
                mountpoint = spacePath name;
                inherit mountOptions;
              }) fs.spaces;
            };
          };
        }
        // lib.listToAttrs (
          lib.imap0 (index: device: {
            name = "${label}-member-${toString index}";
            value = {
              type = "disk";
              inherit device;
              destroy = false;
              content = {
                type = "gpt";
                partitions = { };
              };
            };
          }) members
        );
    in
    {
      imports = [ inputs.disko.nixosModules.disko ];

      # ── settings ────────
      disko.devices.disk = {
        main = {
          type = "disk";
          device = lib.head boot.devices;
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                priority = 1;
                type = "EF00";
                size = "1G"; # room for a second OS's loader and several kernels
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                };
              };

              root = {
                priority = 3;
                content = {
                  type = "btrfs";
                  extraArgs = [ "-f" ];
                  subvolumes = {
                    "/root" = subvolume "/";
                    "/nix" = subvolume "/nix";
                    "/persist" = subvolume "/persist";
                    "/home" = subvolume "/home";
                  };
                };
              }
              // (if boot.reserve == 0 then { size = "100%"; } else { end = "-${toString boot.reserve}G"; });
            }
            // lib.optionalAttrs (boot.swap > 0) {
              swap = {
                priority = 2;
                size = "${toString boot.swap}G";
                content = {
                  type = "swap";
                  discardPolicy = "both";
                };
              };
            };
          };
        };
      }
      // lib.concatMapAttrs disks storage;

      # by label, not disko's first device path, so the mount survives replacing that disk
      fileSystems = lib.concatMapAttrs (
        label: fs:
        lib.mapAttrs' (
          name: _: lib.nameValuePair (spacePath name) { device = lib.mkForce "/dev/disk/by-label/${label}"; }
        ) fs.spaces
      ) storage;

      services.btrfs.autoScrub.enable = true;

      # ── checks ────────
      assertions = [
        {
          assertion = lib.length boot.devices == 1;
          message = "hosts/${host.name}/host.toml: disk.boot takes exactly one device";
        }
      ]
      ++ lib.mapAttrsToList (label: fs: {
        assertion = lib.length fs.devices >= minimum.${fs.profile};
        message = "hosts/${host.name}/host.toml: disk.${label} uses ${fs.profile}, which needs ${toString minimum.${fs.profile}} devices";
      }) storage;
    };
}
