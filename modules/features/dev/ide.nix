# JetBrains IDEs with their plugins built in, on desktops. Rider is the all-rounder and
# also writes LaTeX (TeXiFy); WebStorm stays web-only.
{ inputs, lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      withPlugins = inputs.nix-jetbrains-plugins.lib.buildIdeWithPlugins pkgs;
    in
    {
      config = lib.mkIf (config.axon.host.class == "desktop") {
        environment.systemPackages = [
          (withPlugins "rider" [
            "nix-idea"
            "nl.rubensten.texifyidea"
          ])
          (withPlugins "webstorm" [ ])
        ];
      };
    };
}
