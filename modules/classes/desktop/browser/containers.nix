{
  flake.modules.homeManager.desktop = {
    config = {
      programs.zen-browser.profiles.default = {
        containersForce = true;
        containers = {
          "A" = {
            color = "toolbar";
            icon = "fingerprint";
            id = 1;
          };
          "B" = {
            color = "purple";
            icon = "fingerprint";
            id = 2;
          };
          "C" = {
            color = "blue";
            icon = "fingerprint";
            id = 3;
          };
        };
      };
    };
  };
}
