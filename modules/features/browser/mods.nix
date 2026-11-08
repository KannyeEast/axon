# Zen mods; their settings are prefs in the dotfiles (user.js).
{
  flake.modules.homeManager.browser = {
    programs.zen-browser.profiles.default = {
      mods = [
        "378ba8b9-cd36-45f5-88df-595df5288795" # Add new tab urlbar icon
        "570afd9d-96fa-48b5-bad3-0c106757cce9" # Super Sleek UI
        "8039de3b-72e1-41ea-83b3-5077cf0f98d1" # Trackpad Animation
        "a6335949-4465-4b71-926c-4a52d34bc9c0" # Better Find Bar
        "ad97bb70-0066-4e42-9b5f-173a5e42c6fc" # SuperPins
      ];
    };
  };
}
