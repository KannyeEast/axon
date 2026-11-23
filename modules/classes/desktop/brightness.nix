# brightnessctl: backlight control on laptops, through logind, so the user needs no group.
# Settings: none.
# Key: unbound; bind `brightnessctl -c backlight -e -n 1 set 5%+` (and 5%-), which never goes dark.
{ lib, ... }:
{
  flake.modules.nixos.desktop =
    { config, pkgs, ... }:
    lib.mkIf config.axon.laptop {
      environment.systemPackages = [ pkgs.brightnessctl ];
    };
}
