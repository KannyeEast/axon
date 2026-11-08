# GRUB on EFI, listing another OS on the same machine and the last ten generations.
{
  flake.modules.nixos.core = {
    boot.loader = {
      efi.canTouchEfiVariables = true;
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
