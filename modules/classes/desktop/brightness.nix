# Brightness keys step by a ratio, not a fixed percentage: perceived brightness is roughly
# logarithmic, so 5% is invisible at the top of the range and a third of it at the bottom.
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    let
      backlight = pkgs.writeShellApplication {
        name = "backlight";
        runtimeInputs = [
          pkgs.brightnessctl
          pkgs.gawk
        ];
        text = ''
          step=1.25
          floor=1

          cur=$(brightnessctl --class=backlight get)
          max=$(brightnessctl --class=backlight max)

          new=$(awk -v c="$cur" -v m="$max" -v s="$step" -v f="$floor" \
                    -v d="''${1:-up}" '
            BEGIN {
              lo = m * f / 100
              if (lo < 1) lo = 1

              n = (d == "down") ? c / s : c * s

              # Ratios stall on small numbers; guarantee one raw unit of travel.
              if (d == "up" && n - c < 1) n = c + 1
              if (d == "down" && c - n < 1) n = c - 1

              if (n < lo) n = lo
              if (n > m)  n = m

              printf "%d", n + 0.5
            }')

          brightnessctl --class=backlight set "$new"
        '';
      };
    in
    {
      environment.systemPackages = [
        pkgs.brightnessctl
        backlight
      ];
      # lets the user change the backlight without root
      services.udev.packages = [ pkgs.brightnessctl ];
    };
}
