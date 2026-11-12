# Spaces, pinned tabs and live folders, and which sites open in which space.
{ lib, ... }:
{
  flake.modules.homeManager.browser =
    { osConfig, ... }:
    let
      inherit (osConfig.axon) cluster remotes;
      inherit (cluster) domain;
      hasGateway = lib.any (data: lib.elem "gateway" data.host.features) (lib.attrValues cluster.hosts);

      origin = lib.findFirst (name: remotes.${name}.origin && remotes.${name}.web != null) null (
        lib.attrNames remotes
      );

      # one black for every space; spacesForce reapplies it on every switch, so change it here
      tint = {
        red = 0;
        green = 0;
        blue = 0;
      };

      theme = {
        type = "gradient";
        colors = [
          (
            tint
            // {
              algorithm = "floating";
              type = "explicit-lightness";
              lightness = 0;
            }
          )
        ];
        opacity = 1.0;
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
      }
      // lib.optionalAttrs hasGateway {
        # ── development ────────
        "Server" = {
          id = "07324e6b-5fd0-4c7e-8872-0e8bbc66660b";
          url = "https://home.${domain}";
          position = 110;
          workspace = spaces."Development".id;
        };
      }
      // lib.optionalAttrs (origin != null) {
        # the forge origin pushes to; the mirrors are links on the start page
        ${lib.toSentenceCase origin} = {
          id = "e4b71c09-8a3d-4f62-9c15-7d20b6e9f3a8";
          url = "https://${remotes.${origin}.host}";
          position = 150;
          workspace = spaces."Development".id;
        };
      }
      // {
        # ── entertainment ────────
        "F1 Stream" = {
          id = "7f3c9a21-6d84-4e59-b1a7-2c8e5f0d3b46";
          url = "https://f1live.dpdns.org/1";
          position = 201;
          workspace = spaces."Entertainment".id;
        };

        # ── admin ────────
        "Mail" = {
          id = "b2d84f19-5c73-4e0a-8f26-3d91c7a5e408";
          url = "https://mail.proton.me/";
          position = 301;
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

      # ── spaces (routing) ────────
      spaces = {
        "Development" = {
          id = "779e73b8-5f81-4538-9d92-e7da96824c56";
          position = 2;
          inherit theme;
          routes = {
            "forges" = regexMatch "github|gitlab|codeberg|sr\\.ht|sourcehut";
            "nix" = regexMatch "nixos|nixpkgs|noogle|nixpk\\.gs|nix-community|determinate";
            "docs" = regexMatch "rust-lang|crates\\.io|docs\\.rs|developer\\.mozilla|devdocs|kernel\\.org|man7";
            "help" = regexMatch "stackoverflow|stackexchange|serverfault|superuser";
            "tools" = regexMatch "regex101|starship\\.rs|quickshell|just\\.systems";
            "infra" = regexMatch (
              "dash\\.cloudflare|192\\.168\\.|tailscale"
              + lib.optionalString (domain != null) "|${lib.escapeRegex domain}"
            );
          };
        };

        "Entertainment" = {
          id = "a8fde799-77d2-4b1c-8c83-37dce87d30be";
          position = 1;
          inherit theme;
          routes = {
            "video" = regexMatch "youtube|youtu\\.be|twitch|vimeo|odysee";
            "music" = regexMatch "spotify|bandcamp|soundcloud|last\\.fm";
            "streaming" = regexMatch "netflix|formula1|streamed|dpdns";
          };
        };

        "Admin" = {
          id = "6698068a-20c7-436b-9351-b024cde94686";
          position = 3;
          inherit theme;
          routes = {
            "accounts" = regexMatch "proton\\.me|simplelogin|keepass";
            "bank" = regexMatch "sparkasse";
            "shopping" = regexMatch "amazon|ebay|kleinanzeigen";
          };
        };
      };
    in
    {
      programs.zen-browser.profiles.default = {
        pinsForce = true;
        spacesForce = true;
        inherit pins spaces liveFolders;

        spaceRouting.defaultExternalRoute = "most-recent-space";
      };
    };
}
