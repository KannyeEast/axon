# Nix owns the system; dotfiles own taste.
# home/ holds the dotfiles every host shares, hosts/<name>/home the exceptions; both mirror
# $HOME and the host's file wins. Every file is a symlink into the live checkout, so editing
# either side edits the same file. A watcher handles what a link can't: files added, removed
# or renamed show up within a moment, and a 15 minute resync restores links deleted from ~.
# Nix never reads these files.
{ inputs, ... }:
{
  flake.modules.nixos.core =
    { config, ... }:
    {
      imports = [ inputs.home-manager.nixosModules.home-manager ];

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "bak";
        users.${config.axon.user.name}.home.stateVersion = config.axon.host.state;
      };
    };

  flake.modules.homeManager.core =
    {
      config,
      lib, # the home-manager lib: only it has lib.hm.dag
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (osConfig.axon) host repo;
      own = "${repo}/hosts/${host.name}/home";
      shared = "${repo}/home";

      sync = pkgs.writeShellApplication {
        name = "dotfiles-sync";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
        ];
        text = ''
          own=${lib.escapeShellArg own}
          shared=${lib.escapeShellArg shared}
          dst=${lib.escapeShellArg config.home.homeDirectory}

          # drop links into either source whose file is gone; ownership is read off the link target
          for src in "$own" "$shared"; do
            # a file at the top of ~ has no folder left to be found through below
            find "$dst" -maxdepth 1 -xtype l -lname "$src/*" -delete
            [ -d "$src" ] || continue
            while IFS= read -r top; do
              [ -e "$dst/$top" ] || continue
              find "$dst/$top" -xtype l -lname "$src/*" -delete
            done < <(find "$src" -mindepth 1 -maxdepth 1 -printf '%P\n')
          done

          # link every file; the host's own file wins over the shared one
          for src in "$own" "$shared"; do
            [ -d "$src" ] || continue
            while IFS= read -r rel; do
              [ "$src" = "$shared" ] && [ -e "$own/$rel" ] && continue
              link="$dst/$rel"

              # already pointing at the right file
              [ "$(readlink -- "$link" 2>/dev/null)" = "$src/$rel" ] && continue

              # never overwrite a real file; atomic-save editors replace links with files
              if [ -e "$link" ] && [ ! -L "$link" ]; then
                echo "dotfiles: $link is a real file, moving it to $link.bak" >&2
                mv -- "$link" "$link.bak"
              fi

              mkdir -p -- "$(dirname -- "$link")"
              ln -sfnT -- "$src/$rel" "$link"
            done < <(find "$src" -type f -printf '%P\n')
          done
        '';
      };

      watch = pkgs.writeShellScript "dotfiles-watch" ''
        while :; do
          ${lib.getExe sync} || true
          dirs=()
          for d in ${lib.escapeShellArg own} ${lib.escapeShellArg shared}; do
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
      home.activation.dotfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
