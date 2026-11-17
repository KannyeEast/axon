# Backlight control on laptops (facter); a desktop's monitor has none. Bind the keys to
# `brightnessctl -c backlight -e -n 1 set 5%+` (and 5%-): exponential steps, never fully dark.
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
