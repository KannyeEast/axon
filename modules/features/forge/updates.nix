# Renovate: nightly pull requests for newer flake inputs and images, as renovate.json5 says, when
# cluster.toml [repo]'s origin is this Forgejo; its clone and cache are made again after a reboot.
{ lib, ... }:
{
  flake.modules.nixos.forge =
    { config, ... }:
    let
      inherit (config.axon) cluster remotes;
      inherit (config.axon.services.git) route;
      secret = name: config.sops.secrets."forge/${name}".path;
      origin = lib.findFirst (remote: remote.origin) null (lib.attrValues remotes);
      own = origin != null && origin.web != null && cluster.domain != null && origin.host == route.host;
      hasGithub = lib.hasAttrByPath [ "forge" "github-token" ] config.axon.secrets;
    in
    lib.mkIf own {
      sops.secrets = {
        "forge/renovate-token" = { };
      }
      // lib.optionalAttrs hasGithub { "forge/github-token" = { }; };

      services.renovate = {
        enable = true;
        schedule = "daily";
        # the nix manager updates flake.lock with nix itself
        runtimePackages = [ config.nix.package ];
        credentials = {
          RENOVATE_TOKEN = secret "renovate-token";
        }
        // lib.optionalAttrs hasGithub { RENOVATE_GITHUB_COM_TOKEN = secret "github-token"; };
        settings = {
          platform = "forgejo";
          endpoint = "${route.origin}/api/v1";
          repositories = [ (lib.removePrefix "https://${origin.host}/" origin.web) ];
          # a repository without renovate.json5 is left alone, not sent a pull request adding one
          onboarding = false;
          # the repository's schedules read in this host's time
          timezone = config.axon.locale.timezone;
        };
      };
    };
}
