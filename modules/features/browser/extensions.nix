# Extensions as policy: the ones here and in axon.browser are installed, every other is blocked.
{ lib, ... }:
let
  inherit (lib) isString mapAttrs;
in
{
  flake.modules.homeManager.browser =
    { osConfig, ... }:
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
        _: entry: if isString entry then mkExtensionEntry { id = entry; } else mkExtensionEntry entry
      );

      extensions = {
        "uBlock0@raymondhill.net" = {
          id = "ublock-origin";
          pinned = true;
          private = true;
        };
        "{d867162c-4c38-4c5f-aca4-db6a6592d7da}" = "youtube-tweaks"; # until a custom extension replaces it
        "{b8326f03-322f-4112-96bd-e7996548d99f}" = "theater-mode-for-youtube"; # until a custom extension replaces it
        "deArrow@ajay.app" = "dearrow";
        "sponsorBlocker@ajay.app" = "sponsorblock";
        "harper@writewithharper.com" = "private-grammar-checker-harper";
        "gdpr@cavi.au.dk" = {
          id = "consent-o-matic";
          private = true;
        };
      }
      // osConfig.axon.browser.extensions;
    in
    {
      programs.zen-browser.policies.ExtensionSettings = mkExtensionSettings extensions // {
        "*" = {
          blocked_install_message = "Add extensions in the axon config";
          install_sources = [ "https://addons.mozilla.org/*" ];
          installation_mode = "blocked";
        };
      };
    };
}
