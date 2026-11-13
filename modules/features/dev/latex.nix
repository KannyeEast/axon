# TeX Live on desktops for writing documents in nvim (vimtex, texlab for completion and errors).
# scheme-medium covers the usual classes and packages; latexmk does the rebuilds.
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
