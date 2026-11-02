{ inputs, ... }:
{
  flake.modules.homeManager.desktop =
    { pkgs, ... }:
    {
      imports = [ inputs.zen-browser.homeModules.beta ];

      programs.zen-browser = {
        enable = true;
        setAsDefaultBrowser = true;
        # lets the KeePassXC extension talk to the app
        nativeMessagingHosts = [ pkgs.keepassxc ];
      };
    };
}
