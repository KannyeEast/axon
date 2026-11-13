# Every [disk.<label>] in host.toml but disk.boot: one btrfs filesystem each, on one disk or an
# array. disko has no multi-device type, so the first device carries the filesystem and names the
# others for mkfs.btrfs; the others get an empty table.
{ lib, ... }:
let
  inherit (lib) mkOption types;

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

  # metadata as safe as the data: mkfs.btrfs defaults to DUP on one device and raid1 on several,
  # which covers single and raid0; parity profiles can lose metadata on a crash, so mirror it
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
          subvolumes = lib.mapAttrs' (
            subvolume: mountpoint: lib.nameValuePair subvolume { inherit mountpoint mountOptions; }
          ) fs.mounts;
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
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) host;
      storage = removeAttrs config.axon.disk [ "boot" ];
    in
    {
      options.axon.volumes = mkOption {
        type = types.attrsOf types.str;
        readOnly = true;
        default = lib.concatMapAttrs (_: fs: fs.mounts) storage;
        defaultText = "the mounts of every [disk.<label>] table";
        description = "This host's data disks, name to mountpoint. A feature that can't work without a volume asserts it; one that can falls back to its state folder.";
      };

      config = {
        assertions = lib.mapAttrsToList (label: fs: {
          assertion = lib.length fs.devices >= minimum.${fs.profile};
          message = "hosts/${host.name}/host.toml: disk.${label} uses ${fs.profile}, which needs ${toString minimum.${fs.profile}} devices";
        }) storage;

        disko.devices.disk = lib.concatMapAttrs disks storage;

        # disko mounts by the first device's path; by label the mount still finds the filesystem
        # after that disk is replaced
        fileSystems = lib.concatMapAttrs (
          label: fs:
          lib.mapAttrs' (
            _: mountpoint: lib.nameValuePair mountpoint { device = lib.mkForce "/dev/disk/by-label/${label}"; }
          ) fs.mounts
        ) storage;

        services.btrfs.autoScrub.enable = true;
      };
    };
}
