# Renovate on the forge host: every night it opens pull requests on this Forgejo for newer flake
# inputs and container images, as renovate.json5 at the repository's root says; the check and
# review workflow then handles them like any other pull request. It works as the Forgejo account
# whose token is forge/renovate-token in secrets.json, on the repository cluster.toml [repo]
# origin names, and only when that lives on this Forgejo. With forge/github-token as well, it asks
# GitHub with that token, past the limit on anonymous calls. Its clone and cache don't survive a
# reboot; the next run makes them again.
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
          # a repository without its renovate.json5 is left alone, not sent a pull request adding one
          onboarding = false;
          # the repository's schedules read in this host's time
          timezone = config.axon.locale.timezone;
        };
      };
    };
}
