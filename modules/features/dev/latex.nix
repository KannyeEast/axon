# TeX Live for writing documents (in Rider through TeXiFy), on desktops.
# scheme-medium covers the usual classes and packages; latexmk does the rebuilds.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    {
      config = lib.mkIf (config.axon.host.class == "desktop") {
        environment.systemPackages = [
          (pkgs.texliveMedium.withPackages (ps: [ ps.latexmk ]))
          # the preview TeXiFy opens, with SyncTeX between source and PDF; PDFs otherwise open in the browser
          pkgs.zathura
        ];
      };
    };
}
