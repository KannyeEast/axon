# JetBrains Rider and WebStorm: IDEs on desktops.
# Settings: ~/.ideavimrc.
# Windows: jetbrains-rider, jetbrains-webstorm; their Welcome windows float.
{ inputs, lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      withPlugins = inputs.nix-jetbrains-plugins.lib.buildIdeWithPlugins pkgs;
      # the 1xx band: its analyzers' quick fixes are built against the Roslyn Rider bundles (5.0);
      # later bands need a newer one, and Rider fails to load them
      dotnet = pkgs.dotnetCorePackages.sdk_10_0_1xx;
      # read on top of the IDE's bundled options, in place of nixpkgs' empty file
      vmOptions = pkgs.writeText "jetbrains.vmoptions" "-Didea.trust.all.projects=true\n";
      common = [
        "nix-idea"
        "dev.kdl"
        "org.toml.lang"
        "com.chrisrm.idea.MaterialThemeUI"
        "IdeaVIM"
        "org.mvnsearch.plugins.justPlugin"
      ];
    in
    lib.mkIf (config.axon.host.class == "desktop") {
      # installed globally, so Rider loads projects however it's started
      environment.systemPackages = [
        dotnet
        (withPlugins "rider" common)
        (withPlugins "webstorm" common)
      ];
      environment.sessionVariables = {
        DOTNET_ROOT = "${dotnet}/share/dotnet";
        RIDER_VM_OPTIONS = vmOptions;
        WEBIDE_VM_OPTIONS = vmOptions;
      };
    };
}
