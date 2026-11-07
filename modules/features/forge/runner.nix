# CI on this host: a Forgejo runner that runs jobs right here (runs-on: native), with Nix, git and
# Node at hand, so a repository's workflow can check and build its flake. Only this forge's own
# repositories send it jobs. It registers with the UUID in host.toml [forge] runner and the token
# in secrets.json at forge/runner, both shown when the runner is created in Forgejo (Site
# Administration → Actions → Runners → Create new runner). Without a UUID there is no runner.
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
            token = null;
          };
        };
        secrets.server.connections.forgejo.token_url = config.sops.secrets."forge/runner".path;
        hostPackages = [
          pkgs.bash
          pkgs.coreutils
          pkgs.curl
          pkgs.findutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.nodejs
          config.nix.package
        ];
      };

      # it registers with Forgejo on start, so Forgejo has to be up first
      systemd.services.forgejo-runner-native = {
        after = [ "forgejo.service" ];
        wants = [ "forgejo.service" ];
      };

      axon.persist.state.directories = [
        {
          directory = "/var/lib/private/forgejo-runner";
          mode = "0700";
        }
      ];
    };
}
