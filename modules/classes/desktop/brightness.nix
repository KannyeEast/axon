# On laptops, as facter reports them; a desktop's monitor has no backlight to control here.
# Bind the brightness keys to `brightnessctl -c backlight -e -n 1 set 5%+` (and 5%-): -e steps
# along an exponential curve, as brightness is perceived roughly logarithmically, and -n 1 keeps
# the screen from going fully dark.
{ lib, ... }:
{
  flake.modules.nixos.desktop =
    { config, pkgs, ... }:
    lib.mkIf ((config.hardware.facter.report.hardware.system.form_factor or "") == "laptop") {
      environment.systemPackages = [ pkgs.brightnessctl ];
      # lets the user change the backlight without root
      services.udev.packages = [ pkgs.brightnessctl ];
    };
}
