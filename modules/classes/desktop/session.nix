# The desktop class: niri behind GDM, plus the plumbing apps expect.
# Which bar, launcher and keybinds run is taste: hosts/<name>/home/.config/niri.
{ lib, ... }:
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      programs.niri.enable = true;
      services.displayManager.gdm.enable = true;

      security.polkit.enable = true;
      programs.dconf.enable = true;
      services.speechd.enable = false;

      # the account picture on the login screen
      axon.persist.directories = [ "/var/lib/AccountsService" ];

      environment.sessionVariables = {
        NIXOS_OZONE_WL = "1";
        TERMINAL = "alacritty";
      };

      # niri's startup.kdl decides what runs
      environment.systemPackages = [
        pkgs.alacritty
        pkgs.fuzzel
        pkgs.waybar
        pkgs.swaybg
        pkgs.swayidle
        pkgs.swaylock
        pkgs.kanshi
        pkgs.xwayland-satellite # niri starts it on demand when it's on PATH
        pkgs.wl-clipboard
        pkgs.libnotify
        pkgs.mako # makoctl
        pkgs.playerctl
        pkgs.pavucontrol
        pkgs.bibata-cursors
      ];
      security.pam.services.swaylock = { };

      # mako starts on the first notification through D-Bus; nothing has to spawn it
      services.dbus.packages = [ pkgs.mako ];

      # the password prompt for anything that asks polkit (mounting, virt-manager, …)
      systemd.user.services.polkit-agent = {
        description = "polkit authentication agent";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = lib.getExe' pkgs.lxqt.lxqt-policykit "lxqt-policykit-agent";
          Restart = "on-failure";
        };
      };
    };
}
