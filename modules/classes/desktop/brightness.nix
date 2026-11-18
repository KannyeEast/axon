# Backlight control on laptops (facter); a desktop's monitor has none. brightnessctl sets it through
# logind, so the user needs no group. Bind the keys to
# `brightnessctl -c backlight -e -n 1 set 5%+` (and 5%-): exponential steps, never fully dark.
{ lib, ... }:
{
  flake.modules.nixos.desktop =
    { config, pkgs, ... }:
    lib.mkIf config.axon.laptop {
      environment.systemPackages = [ pkgs.brightnessctl ];
    };
}
