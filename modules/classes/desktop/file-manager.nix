# Nautilus: files, with a space-bar preview, video thumbnails and "Open in Terminal".
# Settings: ~/.config/gtk-3.0/bookmarks.
# Windows: org.gnome.Nautilus, its Open and Save dialogs float. Key: Mod+E.
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.nautilus
        pkgs.ffmpegthumbnailer
      ];
      programs.nautilus-open-any-terminal = {
        enable = true;
        terminal = "alacritty";
      };

      services.gnome.sushi.enable = true;
      # off for every GTK app, which also takes Recent out of the sidebar
      programs.dconf.profiles.user.databases = [
        { settings."org/gnome/desktop/privacy".remember-recent-files = false; }
      ];
    };
}
