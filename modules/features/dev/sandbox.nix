# `sandbox` opens a rootless podman container that can see the current folder and nothing
# else of yours: no ~, no SSH keys, no secrets. `sandbox claude` runs Claude Code in it;
# without arguments it's a shell for trying untrusted code.
# The container's home (Claude's login, shell history) persists in ~/.local/share/sandbox.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      image = pkgs.dockerTools.streamLayeredImage {
        name = "sandbox";
        contents = [
          pkgs.bashInteractive
          pkgs.cacert
          pkgs.ccusage
          pkgs.claude-code
          pkgs.coreutils
          pkgs.diffutils
          pkgs.fd
          pkgs.findutils
          pkgs.gawk
          pkgs.git
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gnutar
          pkgs.gzip
          pkgs.jq
          pkgs.less
          pkgs.neovim
          pkgs.nix
          pkgs.nodejs
          pkgs.python3
          pkgs.ripgrep
          pkgs.shellcheck
          pkgs.which
        ];
        extraCommands = "mkdir -m 1777 tmp";
        config = {
          Env = [
            "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
            "HOME=/home/sandbox"
            "TERM=xterm-256color"
            # Ctrl+G in Claude Code opens the prompt in it
            "EDITOR=nvim"
            # nix talks to the host's daemon (see the mounts below); its nix.conf isn't visible here
            "NIX_REMOTE=daemon"
            "NIX_CONFIG=experimental-features = nix-command flakes"
            # commits made in here carry the user's identity; there is no key, so they're unsigned
            "GIT_AUTHOR_NAME=${config.axon.user.name}"
            "GIT_AUTHOR_EMAIL=${config.axon.user.email}"
            "GIT_COMMITTER_NAME=${config.axon.user.name}"
            "GIT_COMMITTER_EMAIL=${config.axon.user.email}"
          ];
          WorkingDir = "/work";
          Cmd = [ "bash" ];
        };
      };

      sandbox = pkgs.writeShellApplication {
        name = "sandbox";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.podman
        ];
        text = ''
          name="sandbox:${image.imageTag}"

          # the image is built by Nix; load it the first time this version is used
          if ! podman image exists "$name"; then
            ${image} | podman load >/dev/null
          fi

          state="''${XDG_DATA_HOME:-$HOME/.local/share}/sandbox"
          mkdir -p "$state"

          # personal settings stay in the dotfiles, read-only in here: edit them there. Dotfiles
          # are links into the checkout, so every file is mounted by its real path, never a folder.
          # ~/.config/claude/<path> is ~/.claude/<path> in here (CLAUDE.md, agents/, …), except
          # settings.json: claude gets that through --settings, so it wins over ~/.claude's own
          # settings.json, which stays writable for what a session changes
          config="''${XDG_CONFIG_HOME:-$HOME/.config}"
          opts=()
          mirror() {
            local from=$1 to=$2 rel target
            [ -d "$from" ] || return 0
            while IFS= read -r rel; do
              target="$to/$rel"
              [ "$from/$rel" = "$config/claude/settings.json" ] && target=/home/sandbox/.config/claude/settings.json
              opts+=(--volume "$(readlink -f "$from/$rel"):$target:ro")
            done < <(find -L "$from" -type f -printf '%P\n')
          }
          mirror "$config/claude" /home/sandbox/.claude
          # other tools Claude Code runs keep their own place
          for tool in caveman ccstatusline; do
            mirror "$config/$tool" "/home/sandbox/.config/$tool"
          done

          # keys tools in here need (CONTEXT7_API_KEY=…), kept outside the dotfiles: they go public
          secrets="$config/sandbox/secrets.env"
          [ -f "$secrets" ] && opts+=(--env-file "$secrets")

          args=("$@")
          if [ "''${1:-}" = claude ]; then
            args=(claude)
            [ -e "$config/claude/settings.json" ] \
              && args+=(--settings /home/sandbox/.config/claude/settings.json)
            # MCP servers of our own; the file is mirrored like the rest of ~/.config/claude
            [ -e "$config/claude/mcp.json" ] && args+=(--mcp-config /home/sandbox/.claude/mcp.json)
            args+=("''${@:2}")
          fi

          # the host's store, read-only, and its daemon: evals and builds use the host's cache
          # instead of a second store. The store is world-readable on the host anyway; secrets
          # never enter it.
          exec podman run --rm -it \
            --userns=keep-id \
            --volume /nix/store:/nix/store:ro \
            --volume /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket \
            --volume "$PWD:/work" \
            --volume "$state:/home/sandbox" \
            "''${opts[@]}" \
            --workdir /work \
            "$name" "''${args[@]:-bash}"
        '';
      };
    in
    lib.mkIf (config.axon.host.class == "desktop") {
      environment.systemPackages = [ sandbox ];
    };
}
