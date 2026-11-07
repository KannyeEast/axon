# Printing, with network printers found automatically.
{
  flake.modules.nixos.printing = {
    services.printing.enable = true;
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    axon.persist.state.directories = [ "/var/lib/cups" ];
  };
}
