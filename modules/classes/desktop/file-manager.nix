# Nautilus, with a preview on the space bar, video thumbnails and "Open in Terminal".
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.nautilus
        pkgs.ffmpegthumbnailer
      ];

      services.gnome.sushi.enable = true;

      programs.nautilus-open-any-terminal = {
        enable = true;
        terminal = "alacritty";
      };
    };
}
