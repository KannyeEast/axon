# Every [disk.<label>] table in host.toml except disk.boot: one btrfs filesystem each, on one disk or as an array.
# disko has no multi-device type, so an array is written the way mkfs.btrfs takes it:
# the first device carries the filesystem and names the others; the others get an empty table.
{ lib, ... }:
let
  inherit (lib)
    attrValues
    concatMapAttrs
    head
    imap0
    length
    listToAttrs
    mapAttrs'
    mapAttrsToList
    mkForce
    nameValuePair
    tail
    ;

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

  # parity profiles can lose metadata on a crash; mirror it instead
  metadataFor = profile: if profile == "raid5" || profile == "raid6" then "raid1c3" else profile;

  mountOptions = [
    "compress=zstd:1"
    "noatime"
    "nofail" # a missing data disk must not stop the boot
    "x-systemd.device-timeout=10s"
  ];

  disks =
    label: fs:
    let
      members = tail fs.devices;
    in
    {
      ${label} = {
        type = "disk";
        device = head fs.devices;
        destroy = false; # only the boot disk is ever wiped
        content = {
          type = "btrfs";
          extraArgs = [
            "-f"
            "-L"
            label
            "-d"
            fs.profile
            "-m"
            (metadataFor fs.profile)
          ]
          ++ members;
          subvolumes = mapAttrs' (
            subvolume: mountpoint: nameValuePair subvolume { inherit mountpoint mountOptions; }
          ) fs.mounts;
        };
      };
    }
    // listToAttrs (
      imap0 (index: device: {
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
      inherit (config.axon.host) name;
      storage = removeAttrs config.axon.disk [ "boot" ];
    in
    {
      assertions = mapAttrsToList (label: fs: {
        assertion = length fs.devices >= minimum.${fs.profile};
        message = "hosts/${name}/host.toml: disk.${label} uses ${fs.profile}, which needs ${toString minimum.${fs.profile}} devices";
      }) storage;

      disko.devices.disk = concatMapAttrs disks storage;

      # disko mounts by the first device's path; mounting by label survives losing that disk
      fileSystems = concatMapAttrs (
        label: fs:
        mapAttrs' (
          _: mountpoint: nameValuePair mountpoint { device = mkForce "/dev/disk/by-label/${label}"; }
        ) fs.mounts
      ) storage;

      services.btrfs.autoScrub = {
        enable = storage != { };
        interval = "monthly";
        fileSystems = map (fs: head (attrValues fs.mounts)) (attrValues storage);
      };
    };
}
