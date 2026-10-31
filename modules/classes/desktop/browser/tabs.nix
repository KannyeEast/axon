{ lib, ... }:
let
  inherit (lib)
    optionalAttrs
    optionalString
    ;
in
{
  flake.modules.homeManager.desktop =
    { osConfig, ... }:
    let
      domain = if osConfig.axon.cluster.domain != null then osConfig.axon.cluster.domain else "";
      escapeRegex = builtins.replaceStrings [ "." ] [ "\\." ];

      # one neutral tint for every space; colours are taste and can be set in the browser
      tint = {
        red = 128;
        green = 128;
        blue = 128;
      };

      mkTheme = _: {
        type = "gradient";
        colors = [
          (
            tint
            // {
              algorithm = "floating";
              type = "explicit-lightness";
              lightness = 50;
            }
          )
        ];
        opacity = 0.8;
        texture = 0.0;
      };

      # ── routes ────────
      regexMatch = alternatives: {
        matchType = "regex";
        reference = "^https?://[^/]*(${alternatives})";
      };

      # ── pins ────────
      pins = {
        # ── essentials ────────
        "Proton" = {
          id = "986ce577-0407-46b0-90cb-d2ad8dba406c";
          url = "https://account.proton.me/apps";
          position = 1;
          isEssential = true;
        };
        "Addy" = {
          id = "8e9537c6-400d-4d3f-9dc8-724c4c76cb07";
          url = "https://app.addy.io";
          position = 2;
          isEssential = true;
        };

        # ── development ────────
        # Infrastructure
        "Server" = {
          id = "e0f080f0-6cab-41d5-b416-cc07d318b969";
          position = 110;
          workspace = spaces."Development".id;
          isGroup = true;
          isFolderCollapsed = true;
          editedTitle = true;
          folderIcon = "chrome://browser/skin/zen-icons/selectable/folder.svg";
        };
        "FRITZ!Box" = {
          id = "36a3dbb0-447f-4446-8dd8-df1b169cbc12";
          url = "http://192.168.178.1";
          position = 111;
          workspace = spaces."Development".id;
          folderParentId = pins."Server".id;
        };
        "Cloudflare" = {
          id = "9fb4ee37-0150-4532-ad02-f981f102f16a";
          url = "https://dash.cloudflare.com";
          position = 112;
          workspace = spaces."Development".id;
          folderParentId = pins."Server".id;
        };
        "Tailscale" = {
          id = "53bcb3ca-773e-4b5b-9974-16862c8c18b9";
          url = "https://console.tailscale.com";
          position = 113;
          workspace = spaces."Development".id;
          folderParentId = pins."Server".id;
        };
      }
      // optionalAttrs (domain != "") {
        "Website" = {
          id = "07324e6b-5fd0-4c7e-8872-0e8bbc66660b";
          url = "https://dns.${domain}";
          position = 115;
          workspace = spaces."Development".id;
          folderParentId = pins."Server".id;
        };
      }
      // {

        # Forges
        "Codeberg" = {
          id = "c81d4a6f-2e39-4b57-a0d8-1f6e93b7c052";
          url = "https://codeberg.org/";
          position = 151;
          workspace = spaces."Development".id;
        };
        "GitHub" = {
          id = "fcc811cc-1389-4b0f-8384-949da46ad442";
          url = "https://github.com/";
          position = 152;
          workspace = spaces."Development".id;
        };
        "GitLab" = {
          id = "5a3e9f2b-7c14-4d8e-b6a1-9f0c2e8d4a37";
          url = "https://gitlab.com/";
          position = 153;
          workspace = spaces."Development".id;
        };

        # ── entertainment ────────
        "F1 Stream" = {
          id = "7f3c9a21-6d84-4e59-b1a7-2c8e5f0d3b46";
          url = "https://f1tv.formula1.com/";
          position = 201;
          workspace = spaces."Entertainment".id;
        };
        "F1 Timing" = {
          id = "d5a81e6c-3b09-4f72-8e14-9a7c6b2d5f80";
          url = "https://www.formula1.com/en/timing/f1-live";
          position = 202;
          workspace = spaces."Entertainment".id;
        };

        # ── admin ────────
        "Documents" = {
          id = "27b7c2ce-6856-43c3-b996-b99d4a8b8578";
          url = "https://docs.proton.me/";
          position = 301;
          workspace = spaces."Admin".id;
        };
        "Mail" = {
          id = "b2d84f19-5c73-4e0a-8f26-3d91c7a5e408";
          url = "https://mail.proton.me/";
          position = 302;
          workspace = spaces."Admin".id;
        };
      };

      # ── live folders ────────
      liveFolders = {
        "Issues" = {
          id = "3c9e1f7a-5b24-4d80-9a6c-e2f4b8d10c57";
          kind = "github:issues";
          workspace = spaces."Development".id;
          position = 102;
          github.authorMe = true;
        };
      };

      # ── joined tabs ────────
      joinedTabs = {
        "Rawe Ceek" = {
          id = "race-split";
          gridType = "hsep";
          tabs = [
            pins."F1 Stream".id
            pins."F1 Timing".id
          ];
          sizes = [
            66
            34
          ];
        };
      };

      # ── spaces (routing) ────────
      spaces = {
        "Development" = {
          id = "779e73b8-5f81-4538-9d92-e7da96824c56";
          position = 2;
          theme = mkTheme "base00";
          routes = {
            "forges" = regexMatch "github|gitlab|codeberg|sr\\.ht|sourcehut";
            "nix" = regexMatch "nixos|nixpkgs|noogle|nixpk\\.gs|nix-community|determinate";
            "docs" = regexMatch "rust-lang|crates\\.io|docs\\.rs|developer\\.mozilla|devdocs|kernel\\.org|man7";
            "help" = regexMatch "stackoverflow|stackexchange|serverfault|superuser";
            "tools" = regexMatch "regex101|starship\\.rs|quickshell|just\\.systems";
            "infra" = regexMatch (
              "dash\\.cloudflare|192\\.168\\.|tailscale" + optionalString (domain != "") "|${escapeRegex domain}"
            );
          };
        };

        "Entertainment" = {
          id = "a8fde799-77d2-4b1c-8c83-37dce87d30be";
          position = 1;
          theme = mkTheme "base00";
          routes = {
            "video" = regexMatch "youtube|youtu\\.be|twitch|vimeo|odysee";
            "music" = regexMatch "spotify|bandcamp|soundcloud|last\\.fm";
            "streaming" = regexMatch "netflix|f1tv|formula1|streamed|dpdns";
          };
        };

        "Admin" = {
          id = "6698068a-20c7-436b-9351-b024cde94686";
          position = 3;
          theme = mkTheme "base00";
          routes = {
            "accounts" = regexMatch "proton\\.me|simplelogin|keepass";
            "bank" = regexMatch "sparkasse";
            "shopping" = regexMatch "amazon|ebay|kleinanzeigen";
          };
        };
      };
    in
    {
      config = {
        programs.zen-browser.profiles.default = {
          pinsForce = true;
          inherit
            pins
            ;

          spacesForce = true;
          inherit
            spaces
            ;

          inherit
            liveFolders
            ;
          inherit
            joinedTabs
            ;

          spaceRouting.defaultExternalRoute = "most-recent-space";
        };
      };
    };
}
