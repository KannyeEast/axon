# The terminal: zsh with its plugins, tmux with its plugins, and the everyday CLI tools.
# Nix installs them and loads the plugins (they need store paths); every setting is a
# dotfile (.zshrc, .config/tmux/tmux.conf, .config/starship.toml, .config/nvim/init.lua).
{
  flake.modules.nixos.terminal =
    { config, pkgs, ... }:
    let
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
          source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh
          source ${pkgs.zsh-history-substring-search}/share/zsh-history-substring-search/zsh-history-substring-search.zsh
          source ${pkgs.zsh-you-should-use}/share/zsh/plugins/you-should-use/you-should-use.plugin.zsh

          eval "$(fzf --zsh)"
        '';
      };

      # cd jumps to frecent folders; the module hooks it in after the block above
      programs.zoxide = {
        enable = true;
        flags = [ "--cmd cd" ];
      };

      programs.tmux = {
        enable = true;
        plugins = [
          pkgs.tmuxPlugins.sensible
          pkgs.tmuxPlugins.yank
          pkgs.tmuxPlugins.resurrect
          pkgs.tmuxPlugins.continuum
        ];
      };

      # nvim as $EDITOR. With plugins the wrapper skips ~/.config/nvim/init.lua, so it loads it here.
      programs.neovim = {
        enable = true;
        defaultEditor = true;
        viAlias = true;
        vimAlias = true;
        configure = {
          packages.axon.start = [
            pkgs.vimPlugins.nvim-treesitter.withAllGrammars
            pkgs.vimPlugins.telescope-nvim
            pkgs.vimPlugins.telescope-fzf-native-nvim
            pkgs.vimPlugins.gitsigns-nvim
            pkgs.vimPlugins.mini-nvim
            pkgs.vimPlugins.nvim-lspconfig
            pkgs.vimPlugins.snacks-nvim
            pkgs.vimPlugins.vimtex
            pkgs.vimPlugins.which-key-nvim
          ];
          customLuaRC = ''
            local init = vim.fn.stdpath("config") .. "/init.lua"
            if vim.uv.fs_stat(init) then
              dofile(init)
            end
          '';
        };
      };

      environment.systemPackages = [
        pkgs.bat
        pkgs.eza
        pkgs.fd
        pkgs.fzf
        pkgs.jq
        pkgs.lazygit
        pkgs.nil
        pkgs.ripgrep
        pkgs.starship
        pkgs.zsh-completions
      ];
    };
}
