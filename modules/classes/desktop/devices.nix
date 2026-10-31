# Things plugged in or nearby: printers, USB drives, firmware.
{
  flake.modules.nixos.desktop = {
    # printing, with network printers found automatically
    services.printing.enable = true;
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    # USB drives show up and mount in the file manager
    services.udisks2.enable = true;
    services.gvfs.enable = true;

    # firmware updates from the vendor (fwupdmgr refresh && fwupdmgr update)
    services.fwupd.enable = true;

    axon.persist.directories = [
      "/var/lib/cups"
      "/var/lib/fwupd"
    ];
  };
}
