# One look from the boot menu on: a dark GRUB theme, then every toolkit dark, with the same cursor
# and fonts. These are defaults; a setting changed in an app still wins.
{ lib, ... }:
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      boot.loader.grub = {
        theme = pkgs.minimal-grub-theme;
        # GRUB draws at the screen's native mode, where text on a 4K screen is tiny
        gfxmodeEfi = "1920x1080,auto";
      };

      programs.dconf.profiles.user.databases = [
        {
          settings."org/gnome/desktop/interface" = {
            color-scheme = "prefer-dark";
            # GTK3 ignores color-scheme
            gtk-theme = "Adwaita-dark";
            cursor-theme = "Bibata-Modern-Ice";
            cursor-size = lib.gvariant.mkInt32 24;
            font-name = "Noto Sans 11";
            monospace-font-name = "JetBrainsMono Nerd Font 11";
          };
        }
      ];

      qt = {
        enable = true;
        platformTheme = "gnome";
        style = "adwaita-dark";
      };
    };
}
