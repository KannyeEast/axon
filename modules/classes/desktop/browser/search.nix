{
  flake.modules.homeManager.desktop =
    { pkgs, ... }:
    let
      nixIcon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
    in
    {
      config = {
        programs.zen-browser.profiles.default.search = {
          force = true;

          default = "Kagi";
          privateDefault = "Kagi";

          engines = {
            "Kagi" = {
              urls = [
                {
                  template = "https://kagi.com/search";
                  params = [
                    {
                      name = "q";
                      value = "{searchTerms}";
                    }
                  ];
                }
              ];
              icon = "https://kagi.com/favicon.ico";
              definedAliases = [ "@k" ];
            };

            "NixOS Packages" = {
              urls = [
                {
                  template = "https://search.nixos.org/packages";
                  params = [
                    {
                      name = "channel";
                      value = "unstable";
                    }
                    {
                      name = "type";
                      value = "packages";
                    }
                    {
                      name = "query";
                      value = "{searchTerms}";
                    }
                  ];
                }
              ];
              icon = nixIcon;
              definedAliases = [ "@np" ];
            };

            "NixOS Options" = {
              urls = [
                {
                  template = "https://mynixos.com/search";
                  params = [
                    {
                      name = "q";
                      value = "{searchTerms}";
                    }
                  ];
                }
              ];
              icon = nixIcon;
              definedAliases = [ "@no" ];
            };

            "Home Manager Options" = {
              urls = [
                {
                  template = "https://search.nixos.org/options";
                  params = [
                    {
                      name = "channel";
                      value = "unstable";
                    }
                    {
                      name = "type";
                      value = "options";
                    }
                    {
                      name = "query";
                      value = "{searchTerms}";
                    }
                    {
                      name = "source";
                      value = "home_manager";
                    }
                  ];
                }
              ];
              icon = nixIcon;
              definedAliases = [ "@hm" ];
            };

            "Noogle" = {
              urls = [
                {
                  template = "https://noogle.dev/q";
                  params = [
                    {
                      name = "term";
                      value = "{searchTerms}";
                    }
                  ];
                }
              ];
              icon = nixIcon;
              definedAliases = [ "@ng" ];
            };

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
    };
}
