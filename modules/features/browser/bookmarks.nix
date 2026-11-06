# Bookmarks. Anything tagged "shortcut" also becomes a new-tab tile.
{ lib, ... }:
let
  inherit (lib)
    concatMap
    elem
    filter
    optionalAttrs
    toJSON
    ;

  # get icons: curl -sL <website url> | grep -oE '<link[^>]+(icon|manifest)[^>]*>'
  tree = [
    {
      name = "Tools";
      bookmarks = [
        {
          name = "Regex";
          url = "https://regex101.com/";
          tags = [
            "shortcut"
            "tool"
          ];
        }
        {
          name = "UUID Generator";
          url = "https://www.uuidgenerator.net/";
          tags = [
            "shortcut"
            "tool"
          ];
        }
      ];
    }
    {
      name = "Streaming";
      bookmarks = [
        {
          name = "F1TV";
          url = "https://f1tv.formula1.com/";
          icon = "https://f1tv.formula1.com/static/favicon-512x512.png";
          tags = [
            "shortcut"
            "streaming"
          ];
        }
        {
          name = "F1";
          url = "https://f1live.dpdns.org/1";
          icon = "https://f1live.dpdns.org/favicon.ico?favicon.2vob68tjqpejf.ico";
          tags = [
            "shortcut"
            "streaming"
          ];
        }
        {
          name = "Football";
          url = "https://strmd.link/";
          tags = [
            "shortcut"
            "streaming"
          ];
        }
      ];
    }
  ];

  flatten = items: concatMap (b: if b ? bookmarks then flatten b.bookmarks else [ b ]) items;

  forBookmarks = map (
    b:
    if b ? bookmarks then
      b // { bookmarks = forBookmarks b.bookmarks; }
    else
      removeAttrs b [
        "icon"
        "iconSize"
      ]
  );

  shortcuts = map (
    b:
    {
      inherit (b) url;
      label = b.name;
    }
    // optionalAttrs (b ? icon) {
      smallFavicon = b.icon;
      favicon = b.icon;
      faviconSize = b.iconSize or 96;
    }
  ) (filter (b: elem "shortcut" (b.tags or [ ])) (flatten tree));
in
{
  flake.modules.homeManager.browser = {
    programs.zen-browser.profiles.default = {
      bookmarks.force = true;
      bookmarks.settings = forBookmarks tree;

      settings = {
        "browser.newtabpage.pinned" = toJSON shortcuts;
      };
    };
  };
}
