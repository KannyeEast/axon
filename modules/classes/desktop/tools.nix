# Small everyday apps: GNOME Calculator and Baobab (disk usage).
# Settings: none.
# Windows: org.gnome.Calculator (floats), org.gnome.baobab.
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
