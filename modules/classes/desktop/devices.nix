# Things plugged in: USB drives and firmware.
{
  flake.modules.nixos.desktop = {
    # USB drives show up and mount in the file manager
    services.udisks2.enable = true;
    services.gvfs.enable = true;

    # firmware updates from the vendor (fwupdmgr refresh && fwupdmgr update)
    services.fwupd.enable = true;

    axon.persist.directories = [ "/var/lib/fwupd" ];
  };
}
