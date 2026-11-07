# Nautilus, with a preview on the space bar, video thumbnails and "Open in Terminal". Recent files
# are off for every GTK app, which also takes Recent out of the sidebar.
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.nautilus
        pkgs.ffmpegthumbnailer
      ];

      services.gnome.sushi.enable = true;

      programs.dconf.profiles.user.databases = [
        { settings."org/gnome/desktop/privacy".remember-recent-files = false; }
      ];

      programs.nautilus-open-any-terminal = {
        enable = true;
        terminal = "alacritty";
      };
    };
}
