# Every project brings its own toolchain as a flake devshell; direnv loads it on cd.
# Start one with: nix flake init -t ~/axon#devshell && direnv allow
{
  flake.templates.devshell = {
    path = ./_devshell;
    description = "A per-project devshell, loaded by direnv";
  };

  flake.modules.nixos.dev =
    { config, ... }:
    {
      programs.direnv = {
        enable = true;
        nix-direnv.enable = true;
        settings = {
          global.hide_env_diff = true;
          # the config repo's own .envrc is trusted without `direnv allow`
          whitelist.prefix = [ config.axon.repo ];
        };
      };
    };
}
