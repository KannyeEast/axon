# Things plugged in: USB drives and firmware.
{
  flake.modules.nixos.desktop = {
    # USB drives show up and mount in the file manager (gvfs brings udisks2)
    services.gvfs.enable = true;

    services.fwupd.enable = true;

    axon.persist.directories = [ "/var/lib/fwupd" ];
  };
}
