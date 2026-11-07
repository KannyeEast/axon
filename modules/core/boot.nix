# GRUB on EFI, listing another OS on the same machine and the last ten generations.
{ lib, ... }:
{
  flake.modules.nixos.core = {
    boot.loader = {
      efi.canTouchEfiVariables = true;
      timeout = lib.mkDefault 5;
      grub = {
        enable = true;
        device = "nodev";
        useOSProber = true;
        efiSupport = true;
        configurationLimit = 10;
      };
    };
  };
}
