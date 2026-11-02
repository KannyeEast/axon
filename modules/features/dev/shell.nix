# The terminal: zsh with its plugins, tmux with its plugins, and the everyday CLI tools.
# Nix installs them and loads the plugins (they need store paths); every setting is a
# dotfile (.zshrc, .config/tmux/tmux.conf, .config/starship.toml).
{ inputs, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      undo = inputs.undo.packages.${pkgs.stdenv.hostPlatform.system}.default;
      omz = "${pkgs.oh-my-zsh}/share/oh-my-zsh";
    in
    {
      users.users.${config.axon.user.name}.shell = pkgs.zsh;

      programs.zsh = {
        enable = true;
        autosuggestions.enable = true;
        syntaxHighlighting.enable = true;

        # fzf-tab has to load after compinit, and NixOS would otherwise run compinit after this block
        enableGlobalCompInit = false;
        interactiveShellInit = ''
          autoload -U compinit && compinit

          source ${omz}/lib/clipboard.zsh
          source ${omz}/plugins/copyfile/copyfile.plugin.zsh
          source ${omz}/plugins/copypath/copypath.plugin.zsh
          source ${omz}/plugins/extract/extract.plugin.zsh
          source ${omz}/plugins/sudo/sudo.plugin.zsh
          source ${undo}/share/undo/undo.zsh
          source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh
          source ${pkgs.zsh-history-substring-search}/share/zsh-history-substring-search/zsh-history-substring-search.zsh
          source ${pkgs.zsh-you-should-use}/share/zsh/plugins/you-should-use/you-should-use.plugin.zsh

          eval "$(fzf --zsh)"
          eval "$(zoxide init --cmd cd zsh)"
        '';
      };

      programs.tmux = {
        enable = true;
        terminal = "tmux-256color";
        plugins = [
          pkgs.tmuxPlugins.sensible
          pkgs.tmuxPlugins.yank
          pkgs.tmuxPlugins.resurrect
          pkgs.tmuxPlugins.continuum
        ];
      };

      # nvim as $EDITOR, with its default config
      programs.neovim = {
        enable = true;
        defaultEditor = true;
        viAlias = true;
        vimAlias = true;
      };

      environment.sessionVariables = {
        UNDO_CAPTURE_SHELL = "1";
        MANPAGER = "sh -c 'col -bx | bat -l man -p'";
        MANROFFOPT = "-c";
        FZF_DEFAULT_COMMAND = "fd --type f --hidden --exclude .git";
        FZF_CTRL_T_COMMAND = "fd --hidden --exclude .git";
        FZF_ALT_C_COMMAND = "fd --type d --hidden --exclude .git";
      };

      environment.systemPackages = [
        undo
        pkgs.bat
        pkgs.eza
        pkgs.fd
        pkgs.fzf
        pkgs.just
        pkgs.jq
        pkgs.ripgrep
        pkgs.starship
        pkgs.zoxide
        pkgs.zsh-completions
      ];
    };
}
