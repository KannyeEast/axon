# Dotfiles: home/ and hosts/<name>/home (which wins per file) linked into $HOME from the live
# checkout; a watcher relinks on change, and a resync every 15 minutes restores deleted links.
{ inputs, lib, ... }:
{
  flake.modules.nixos.core =
    { config, ... }:
    {
      imports = [ inputs.home-manager.nixosModules.home-manager ];

      options.axon.dotfiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default =
          let
            inherit (config.axon) host repo;
          in
          [
            "${repo}/hosts/${host.name}/home"
            "${repo}/home"
          ];
        defaultText = "<repo>/hosts/<name>/home, <repo>/home";
        description = "The dotfile folders in the checkout, the host's own first; each may be missing.";
      };

      config.home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "bak";
        users.${config.axon.user.name}.home.stateVersion = config.axon.host.state;
      };
    };

  flake.modules.homeManager.core =
    {
      config,
      osConfig,
      pkgs,
      ...
    }:
    let
      homes = osConfig.axon.dotfiles;

      sync = pkgs.writeShellApplication {
        name = "dotfiles-sync";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
        ];
        runtimeEnv = {
          DOTFILES = homes;
          LINK_ROOT = config.home.homeDirectory;
          # every link the last run made, for those under a folder neither home has any more
          LINK_LIST = "${config.xdg.stateHome}/dotfiles/links";
        };
        text = builtins.readFile ./_dotfiles-sync.sh;
      };

      watch = pkgs.writeShellScript "dotfiles-watch" ''
        while :; do
          ${lib.getExe sync} || true
          dirs=()
          for d in ${lib.escapeShellArgs homes}; do
            [ -d "$d" ] && dirs+=("$d")
          done
          if [ ''${#dirs[@]} -gt 0 ]; then
            ${lib.getExe' pkgs.inotify-tools "inotifywait"} -t 900 -r -q \
              -e create,delete,move,close_write "''${dirs[@]}" >/dev/null || true
          else
            sleep 900
          fi
          sleep 0.2
        done
      '';
    in
    {
      home.packages = [ sync ];

      # first pass at activation, so a fresh install has its dotfiles before the first login
      home.activation.dotfiles = config.lib.dag.entryAfter [ "writeBoundary" ] ''
        ${lib.getExe sync} || true
      '';

      systemd.user.services.dotfiles = {
        Unit.Description = "Mirror the dotfiles into $HOME";
        Install.WantedBy = [ "default.target" ];
        Service = {
          ExecStart = "${watch}";
          Restart = "always";
        };
      };
    };
}
