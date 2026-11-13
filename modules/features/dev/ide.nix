# JetBrains IDEs on desktops: Rider and WebStorm. .NET is installed globally, so Rider loads
# projects however it's started. Plugins are unpacked into the store, so one that casts to
# JarURLConnection to find its own jar breaks every file lookup: check before adding one.
{ inputs, lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      withPlugins = inputs.nix-jetbrains-plugins.lib.buildIdeWithPlugins pkgs;
      # the 1xx band: its analyzers' quick fixes are built against the Roslyn Rider bundles (5.0);
      # later bands need a newer one, and Rider fails to load them
      dotnet = pkgs.dotnetCorePackages.sdk_10_0_1xx;
      # every project trusted: no prompt, its build scripts and .envrc run on open. Read on top of
      # the IDE's bundled options; overrides nixpkgs' empty default
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
