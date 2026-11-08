# The fonts, and which one fills each default family.
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      fonts = {
        enableDefaultPackages = true;
        packages = [
          pkgs.barlow
          pkgs.inter
          pkgs.noto-fonts
          pkgs.nerd-fonts.jetbrains-mono
        ];
        fontconfig.defaultFonts = {
          serif = [ "Noto Serif" ];
          sansSerif = [ "Noto Sans" ];
          # the family name nerd-fonts.jetbrains-mono actually provides
          monospace = [ "JetBrainsMono Nerd Font" ];
        };
      };
    };
}
