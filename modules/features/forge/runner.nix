# CI: a Forgejo runner for this forge's jobs (runs-on: native) on this host, with Nix, git and Node.
# Its UUID and token come from Site Administration > Actions > Runners > Create new runner.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  axon.schema.forge = {
    options.forge.runner = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "UUID of this host's CI runner; its token goes in secrets.json at git/runner-token.";
    };
  };

  flake.modules.nixos.forge =
    { config, pkgs, ... }:
    let
      inherit (config.axon) forge services;
    in
    lib.mkIf (forge.runner != null) {
      # ── service ────────
      services.forgejo-runner.instances.native = {
        enable = true;
        settings = {
          runner.labels = [ "native:host" ];
          server.connections.forgejo = {
            url = "${services.git.route.internal}/";
            uuid = forge.runner;
            # the module requires it null when the token comes from a file (token_url below)
            token = null;
          };
        };
        secrets.server.connections.forgejo.token_url = config.sops.secrets."git/runner-token".path;
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

      # ── units ────────
      # it registers on start, so Forgejo comes first; a switch leaves it alone, as the job that
      # deploys may run on it: a changed runner takes effect on reboot or `systemctl restart`
      systemd.services.forgejo-runner-native = {
        after = [ "forgejo.service" ];
        wants = [ "forgejo.service" ];
        restartIfChanged = false;
      };

      # ── secrets ────────
      sops.secrets."git/runner-token" = { };

      # ── data ────────
      axon.persist.state.directories = [
        "/var/lib/private/forgejo-runner"
      ];
    };
}
