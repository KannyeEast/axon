# Zen: the default browser.
# Settings: ~/.config/zen/<profile> (user.js, chrome, declared files, bookmarks.html).
# Windows: zen-beta. Key: Mod+B.
{ inputs, ... }:
{
  flake.modules.homeManager.browser =
    { osConfig, ... }:
    {
      imports = [ inputs.zen-browser.homeModules.beta ];

      programs.zen-browser = {
        enable = true;
        inherit (osConfig.axon.browser) policies;
        nativeMessagingHosts = osConfig.axon.browser.nativeHosts;
      };
    };
}
