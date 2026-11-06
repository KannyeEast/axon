# Zen as the default browser; the other files here set it up. What other features need from
# it arrives through axon.browser.
{ inputs, ... }:
{
  flake.modules.homeManager.browser =
    { osConfig, ... }:
    {
      imports = [ inputs.zen-browser.homeModules.beta ];

      programs.zen-browser = {
        enable = true;
        setAsDefaultBrowser = true;
        nativeMessagingHosts = osConfig.axon.browser.nativeHosts;
      };
    };
}
