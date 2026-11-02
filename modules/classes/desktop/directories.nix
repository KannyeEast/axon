# The usual home folders; anything deeper comes from the dotfiles.
{
  flake.modules.homeManager.desktop = {
    xdg.userDirs = {
      enable = true;
      createDirectories = true;
      # desktop, documents, download, pictures and videos keep their ~/<Name> default
      music = null;
      projects = null;
      publicShare = null;
      templates = null;
    };
  };
}
