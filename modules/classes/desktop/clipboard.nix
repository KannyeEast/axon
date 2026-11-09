# Clipboard history through cliphist. Passwords stay out of it: KeePassXC marks what it copies as
# secret and cliphist doesn't store that. `clipboard-pick` lists the history in fuzzel and pastes
# the chosen entry into the focused window.
{ ... }:
{
  flake.modules.nixos.desktop =
    { config, pkgs, ... }:
    let
      pick = pkgs.writeShellApplication {
        name = "clipboard-pick";
        runtimeInputs = [
          pkgs.cliphist
          pkgs.fuzzel
          pkgs.jq
          pkgs.wl-clipboard
          pkgs.wtype
          config.programs.niri.package
        ];
        text = ''
          entry=$(cliphist list | fuzzel --dmenu --with-nth=2 --only-match) || exit 0
          printf '%s' "$entry" | cliphist decode | wl-copy

          # give focus a moment to return from fuzzel; terminals paste with ctrl+shift+v
          sleep 0.1
          case "$(niri msg --json focused-window | jq -r '.app_id // ""')" in
            Alacritty) wtype -M ctrl -M shift v -m shift -m ctrl ;;
            *) wtype -M ctrl v -m ctrl ;;
          esac
        '';
      };
    in
    {
      environment.systemPackages = [ pick ];
    };

  # the history itself, text and images (screenshots), kept by home-manager's watcher units
  flake.modules.homeManager.desktop.services.cliphist.enable = true;
}
