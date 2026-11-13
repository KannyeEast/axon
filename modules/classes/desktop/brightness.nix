# Backlight control on laptops (facter); a desktop's monitor has none. Bind the keys to
# `brightnessctl -c backlight -e -n 1 set 5%+` (and 5%-): -e steps exponentially, as brightness is
# perceived roughly logarithmically, and -n 1 keeps the screen from going fully dark.
{ lib, ... }:
{
  flake.modules.nixos.desktop =
    { config, pkgs, ... }:
    lib.mkIf config.axon.laptop {
      environment.systemPackages = [ pkgs.brightnessctl ];
      # lets the user change the backlight without root
      services.udev.packages = [ pkgs.brightnessctl ];
    };
}
