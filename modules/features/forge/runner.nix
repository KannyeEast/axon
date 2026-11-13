# CI: a Forgejo runner that runs jobs on this host (runs-on: native) with Nix, git and Node at
# hand; only this forge's repositories send it jobs. It registers with the UUID in host.toml
# [forge] runner and the token in secrets.json at forge/runner, both shown when the runner is
# created (Site Administration → Actions → Runners → Create new runner). No UUID, no runner.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  axon.schema.forge = {
    options.forge.runner = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "UUID of this host's CI runner; its token goes in secrets.json at forge/runner.";
    };
  };

  flake.modules.nixos.forge =
    { config, pkgs, ... }:
    let
      inherit (config.axon) forge services;
    in
    lib.mkIf (forge.runner != null) {
      services.forgejo.settings.actions.ENABLED = true;

      sops.secrets."forge/runner" = { };

      services.forgejo-runner.instances.native = {
        enable = true;
        settings = {
          runner.labels = [ "native:host" ];
          server.connections.forgejo = {
            url = "http://${services.git.route.endpoint}/";
            uuid = forge.runner;
            # the module requires it null when the token comes from a file (token_url below)
            token = null;
          };
        };
        secrets.server.connections.forgejo.token_url = config.sops.secrets."forge/runner".path;
        hostPackages = [
          pkgs.bash
          pkgs.claude-code # the pull request reviewer (.forgejo/review.sh)
          pkgs.coreutils
          pkgs.curl
          pkgs.findutils
          pkgs.gawk
          pkgs.git
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
          pkgs.nodejs
          config.nix.package
        ];
      };

      # it registers with Forgejo on start, so Forgejo comes first. A deploy's switch lands while
      # the job its push started still runs, so it leaves the runner alone; a changed runner takes
      # effect on the next reboot or `systemctl restart`
      systemd.services.forgejo-runner-native = {
        after = [ "forgejo.service" ];
        wants = [ "forgejo.service" ];
        restartIfChanged = false;
      };

      axon.persist.state.directories = [
        {
          directory = "/var/lib/private/forgejo-runner";
          mode = "0700";
        }
      ];
    };
}
