# facter enables the radio when it finds one; this file only keeps pairings across reboots
{
  flake.modules.nixos.desktop = {
    axon.persist.directories = [ "/var/lib/bluetooth" ];
  };
}
