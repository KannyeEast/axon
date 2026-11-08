# TeX Live for writing documents in nvim (vimtex, with texlab for completion and errors), on
# desktops. scheme-medium covers the usual classes and packages; latexmk does the rebuilds, and
# zathura shows the PDF next to the source.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      environment.systemPackages = [
        (pkgs.texliveMedium.withPackages (ps: [ ps.latexmk ]))
        pkgs.texlab
        # the preview vimtex opens; PDFs otherwise open in the browser
        pkgs.zathura
      ];
    };
}
