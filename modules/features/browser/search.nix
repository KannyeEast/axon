# Search engines: Kagi by default, a few for Nix, and the built-in ones hidden.
{
  flake.modules.homeManager.browser =
    { pkgs, ... }:
    let
      nixIcon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";

      param = name: value: { inherit name value; };
      query = name: param name "{searchTerms}";
      engine = template: params: icon: alias: {
        urls = [ { inherit template params; } ];
        inherit icon;
        definedAliases = [ alias ];
      };
    in
    {
      programs.zen-browser.profiles.default.search = {
        force = true;

        default = "Kagi";
        privateDefault = "Kagi";

        engines = {
          "Kagi" = engine "https://kagi.com/search" [ (query "q") ] "https://kagi.com/favicon.ico" "@k";

          "NixOS Packages" = engine "https://search.nixos.org/packages" [
            (param "channel" "unstable")
            (param "type" "packages")
            (query "query")
          ] nixIcon "@np";

          "NixOS Options" = engine "https://mynixos.com/search" [ (query "q") ] nixIcon "@no";

          "Home Manager Options" = engine "https://search.nixos.org/options" [
            (param "channel" "unstable")
            (param "type" "options")
            (query "query")
            (param "source" "home_manager")
          ] nixIcon "@hm";

          "Noogle" = engine "https://noogle.dev/q" [ (query "term") ] nixIcon "@ng";

          "bing".metaData.hidden = true;
          "ddg".metaData.hidden = true;
          "ebay".metaData.hidden = true;
          "ecosia".metaData.hidden = true;
          "google".metaData.hidden = true;
          "perplexity".metaData.hidden = true;
          "startpage".metaData.hidden = true;
          "wikipedia".metaData.hidden = true;
        };
      };
    };
}
