# The boot disk layout, fixed because persist.nix depends on it: a root subvolume replaced every
# boot, next to nix, persist and home. host.toml picks the device, swap and space for another OS.
{ inputs, lib, ... }:
let
  subvolume = mountpoint: {
    inherit mountpoint;
    mountOptions = [
      "compress=zstd"
      "noatime"
    ];
  };
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) host;
      boot = config.axon.disk.boot;
    in
    {
      imports = [ inputs.disko.nixosModules.disko ];

      assertions = [
        {
          assertion = lib.length boot.devices == 1;
          message = "hosts/${host.name}/host.toml: disk.boot takes exactly one device";
        }
      ];

      disko.devices.disk.main = {
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
    };
}
