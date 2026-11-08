# Every project brings its own toolchain as a flake devshell; direnv loads it on cd.
# Start one with: nix flake init -t ~/axon#devshell && direnv allow
{
  flake.templates.devshell = {
    path = ./_templates/devshell;
    description = "A per-project devshell, loaded by direnv";
  };

  flake.modules.nixos.dev.programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    settings.global.hide_env_diff = true;
  };
}
