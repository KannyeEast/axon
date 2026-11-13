# Language servers and formatters for nvim on desktops, for what configs and scripts are written
# in: Nix, Lua, shell, TOML, Markdown, JSON, YAML. A project's own languages come from its devshell.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      environment.systemPackages = [
        pkgs.bash-language-server
        pkgs.lua-language-server
        pkgs.marksman
        pkgs.nixd
        pkgs.nixfmt
        # bash-language-server lints with it
        pkgs.shellcheck
        pkgs.shfmt
        pkgs.stylua
        pkgs.taplo
        # JSON (and HTML, CSS)
        pkgs.vscode-langservers-extracted
        pkgs.yaml-language-server
      ];
    };
}
