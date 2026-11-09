# Desktops hibernate into the boot disk's swap partition, when host.toml gives it one.
{ lib, ... }:
{
  flake.modules.nixos.desktop =
    { config, ... }:
    lib.mkIf (config.axon.disk.boot.swap > 0) {
      disko.devices.disk.main.content.partitions.swap.content.resumeDevice = true;
    };
}
