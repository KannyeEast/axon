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
          pkgs.claude-code
          pkgs.coreutils
          pkgs.diffutils
          pkgs.fd
          pkgs.findutils
          pkgs.git
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gnutar
          pkgs.gzip
          pkgs.jq
          pkgs.less
          pkgs.nix
          pkgs.nodejs
          pkgs.python3
          pkgs.ripgrep
          pkgs.which
        ];
        extraCommands = "mkdir -m 1777 tmp";
        config = {
          Env = [
            "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
            "HOME=/home/sandbox"
            "TERM=xterm-256color"
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
        runtimeInputs = [ pkgs.podman ];
        text = ''
          name="sandbox:${image.imageTag}"

          # the image is built by Nix; load it the first time this version is used
          if ! podman image exists "$name"; then
            ${image} | podman load >/dev/null
          fi

          state="''${XDG_DATA_HOME:-$HOME/.local/share}/sandbox"
          mkdir -p "$state"

          # the host's store, read-only, and its daemon: evals and builds use the host's cache
          # instead of a second store. The store is world-readable on the host anyway; secrets
          # never enter it.
          exec podman run --rm -it \
            --userns=keep-id \
            --volume /nix/store:/nix/store:ro \
            --volume /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket \
            --volume "$PWD:/work" \
            --volume "$state:/home/sandbox" \
            --workdir /work \
            "$name" "''${@:-bash}"
        '';
      };
    in
    {
      config = lib.mkIf (config.axon.host.class == "desktop") {
        environment.systemPackages = [ sandbox ];
      };
    };
}
