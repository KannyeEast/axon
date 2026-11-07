# A Stream Deck as a control surface. A daemon runs commands from its dials and keys and draws
# their state on the deck. What each control does lives in the dotfiles, in
# .config/control-surface/layout.toml, which the daemon reloads when saved.
{ lib, ... }:
{
  flake.modules.nixos.deck =
    { pkgs, ... }:
    let
      python = pkgs.python3.withPackages (ps: [
        ps.pillow
        ps.streamdeck
      ]);
    in
    {
      # uaccess has to sort before 73-seat-late, which services.udev.extraRules doesn't
      services.udev.packages = [
        (pkgs.writeTextDir "lib/udev/rules.d/70-stream-deck.rules" ''
          SUBSYSTEM=="usb", ATTR{idVendor}=="0fd9", TAG+="uaccess"
        '')
      ];

      systemd.user.services.control-surface = {
        description = "Stream Deck control surface";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        # the layout's commands see what the desktop has installed
        path = [ "/run/current-system/sw" ];
        serviceConfig = {
          ExecStart = "${lib.getExe' python "python3"} ${./_control-surface/daemon.py}";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    };
}
