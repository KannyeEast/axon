# Bookmarks, in folders.
{
  flake.modules.homeManager.browser = {
    programs.zen-browser.profiles.default = {
      bookmarks.force = true;
      bookmarks.settings = [
        {
          name = "Tools";
          bookmarks = [
            {
              name = "Regex";
              url = "https://regex101.com/";
              tags = [ "tool" ];
            }
            {
              name = "UUID Generator";
              url = "https://www.uuidgenerator.net/";
              tags = [ "tool" ];
            }
          ];
        }
        {
          name = "Streaming";
          bookmarks = [
            {
              name = "F1";
              url = "https://f1live.dpdns.org/1";
              tags = [ "streaming" ];
            }
            {
              name = "Football";
              url = "https://strmd.link/";
              tags = [ "streaming" ];
            }
          ];
        }
      ];
    };
  };
}
