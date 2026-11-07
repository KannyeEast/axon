# Small everyday apps: a calculator and a disk usage viewer.
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.gnome-calculator
        pkgs.baobab
      ];
    };
}
