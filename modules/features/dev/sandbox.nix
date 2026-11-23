# `sandbox` opens a rootless Docker container that sees the current folder, its tools' dotfiles
# (read-only) and the keys in ~/.config/sandbox/secrets.env; not ~, not the SSH keys.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      inherit (config.axon.overlay) network;
      image = pkgs.dockerTools.streamLayeredImage {
        name = "sandbox";
        contents = [
          pkgs.bashInteractive
          pkgs.cacert
          pkgs.claude-code
          pkgs.coreutils
          pkgs.diffutils
          # scripts start with #!/usr/bin/env (npx tools, just recipes); the image has only /bin
          pkgs.dockerTools.usrBinEnv
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
          Cmd = [ "bash" ];
        };
      };

      sandbox = pkgs.writeShellApplication {
        name = "sandbox";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          config.virtualisation.docker.rootless.package
        ];
        runtimeEnv = {
          IMAGE_NAME = "sandbox:${image.imageTag}";
          IMAGE_STREAM = image;
          # Docker passes the host's upstream DNS; the tailnet's resolver also knows the hosts by name
          DNS = lib.optionals (network != null) [
            "--dns"
            network.resolver
          ];
        };
        text = builtins.readFile ./_sandbox.sh;
      };
    in
    {
      environment.systemPackages = [ sandbox ];

      # the user's daemon is a user unit: without lingering it ends with the last SSH session, and
      # a sandbox left running in tmux with it
      users.users.${config.axon.user.name}.linger = lib.mkIf (config.axon.host.class == "server") true;
    };
}
