# Clipboard history through cliphist. Passwords stay out of it: KeePassXC marks what it copies as
# secret and cliphist doesn't store that.
{ lib, ... }:
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.cliphist ];

      systemd.user.services.clipboard-history = {
        description = "clipboard history";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = "${lib.getExe' pkgs.wl-clipboard "wl-paste"} --watch ${lib.getExe pkgs.cliphist} store";
          Restart = "on-failure";
        };
      };
    };
}
