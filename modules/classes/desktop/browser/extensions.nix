{ lib, ... }:
let
  inherit (lib)
    mapAttrs
    ;
in
{
  flake.modules.homeManager.desktop =
    let
      mkExtensionEntry =
        {
          id,
          pinned ? false,
          private ? false,
        }:
        let
          base = {
            install_url = "https://addons.mozilla.org/firefox/downloads/latest/${id}/latest.xpi";
            installation_mode = "force_installed";
            # policy-installed extensions have no private-window toggle; this decides it
            private_browsing = private;
          };
        in
        if pinned then base // { default_area = "navbar"; } else base // { default_area = "menupanel"; };

      mkExtensionSettings = mapAttrs (
        _: entry:
        if builtins.isString entry then mkExtensionEntry { id = entry; } else mkExtensionEntry entry
      );

      extensions = {
        "uBlock0@raymondhill.net" = {
          id = "ublock-origin";
          pinned = true;
          private = true;
        };
        "keepassxc-browser@keepassxc.org" = {
          id = "keepassxc-browser";
          pinned = true;
          private = true;
        };
        "{d867162c-4c38-4c5f-aca4-db6a6592d7da}" = "youtube-tweaks"; # Redundant with custom extensions
        "{b8326f03-322f-4112-96bd-e7996548d99f}" = "theater-mode-for-youtube"; # Redundant with custom extensions
        "deArrow@ajay.app" = "dearrow";
        "sponsorBlocker@ajay.app" = "sponsorblock";
        "firefox@tampermonkey.net" = "tampermonkey";
        "{b86e4813-687a-43e6-ab65-0bde4ab75758}" = "localcdn-fork-of-decentraleyes";
        "harper@writewithharper.com" = "private-grammar-checker-harper";
        "gdpr@cavi.au.dk" = {
          id = "consent-o-matic";
          private = true;
        };
      };
    in
    {
      config = {
        programs.zen-browser.policies.ExtensionSettings = mkExtensionSettings extensions // {
          "*" = {
            blocked_install_message = "Add extensions in the axon config";
            install_sources = [ "https://addons.mozilla.org/*" ];
            installation_mode = "blocked";
          };
        };
      };
    };
}
