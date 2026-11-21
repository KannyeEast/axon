# `session` lends the current folder to a server for a while: Mutagen keeps it in sync with
# ~/sessions/<name> there, where Claude runs in tmux (`sandbox claude --rc`), so the work goes on
# with this machine off and can be picked up from another one.
#   session start [name]   from the project folder: link it, start Claude there, attach
#   session attach [name]  back into a running session
#   session join <name>    on another machine: a copy in ~/sessions/<name>, linked to the same one
#   session leave [name]   end that copy (do this before `end` on the first machine)
#   session end [name]     wait for the last changes, unlink, stop Claude, remove the server's copy
#   session list
# The server is the first one this host may SSH to that lists dev; SESSION_SERVER picks another.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      inherit (config.axon) cluster host;
      servers = lib.attrNames (
        lib.filterAttrs (
          name: data:
          data.host.class == "server"
          && lib.elem "dev" data.host.features
          && lib.elem name (cluster.ssh.${host.name} or [ ])
        ) cluster.hosts
      );
      # build output and caches stay on each machine
      ignored = [
        "result"
        "result-*"
        "target"
        "node_modules"
        ".direnv"
      ];

      session = pkgs.writeShellApplication {
        name = "session";
        # the session's name goes into the server's commands from here, on purpose
        excludeShellChecks = [ "SC2029" ];
        runtimeInputs = [
          pkgs.coreutils
          pkgs.mutagen
          pkgs.openssh
        ];
        text = ''
          server=''${SESSION_SERVER:-${lib.head servers}}
          cmd=''${1:-}
          [ $# -gt 0 ] && shift

          # Mutagen and tmux both want plain names
          name=$(basename "''${1:-$PWD}" | tr -c '[:alnum:]-\n' '-')
          case $name in [[:alpha:]]*) ;; *) name="s-$name" ;; esac
          remote="sessions/$name"

          link() {
            mutagen sync create --name "$name" --label session="$name" \
              ${lib.concatMapStringsSep " " (pattern: "--ignore=${lib.escapeShellArg pattern}") ignored} \
              "$1" "$server:$remote"
            mutagen sync flush "$name"
          }
          attach() { exec ssh -t "$server" tmux attach -t "$name"; }

          case $cmd in
            start)
              link "$PWD"
              ssh "$server" "tmux new-session -d -s '$name' -c \"\$HOME/$remote\" 'sandbox claude --rc'"
              attach
              ;;
            attach) attach ;;
            join)
              [ $# -gt 0 ] || { echo "session join: which session? (session list)" >&2; exit 2; }
              mkdir -p "$HOME/$remote"
              link "$HOME/$remote"
              attach
              ;;
            leave)
              mutagen sync flush "$name"
              mutagen sync terminate "$name"
              rm -rf "''${HOME:?}/$remote"
              ;;
            end)
              mutagen sync flush "$name"
              mutagen sync terminate "$name"
              ssh "$server" "tmux kill-session -t '$name' 2>/dev/null; rm -rf \"\$HOME/$remote\""
              ;;
            list)
              mutagen sync list --label-selector session
              ssh "$server" "tmux ls 2>/dev/null || echo 'no sessions on $server'"
              ;;
            *)
              echo "usage: session start|attach|join|leave|end|list [name]" >&2
              exit 2
              ;;
          esac
        '';
      };
    in
    lib.mkIf (servers != [ ]) {
      environment.systemPackages = [
        session
        pkgs.mutagen
      ];

      # the links outlive a reboot: Mutagen's daemon picks them up again at login
      systemd.user.services.mutagen = {
        description = "Mutagen, which keeps the sessions' folders in sync";
        wantedBy = [ "default.target" ];
        # it, not the session command, connects to the server
        path = [ pkgs.openssh ];
        serviceConfig = {
          ExecStart = "${lib.getExe pkgs.mutagen} daemon run";
          Restart = "on-failure";
        };
      };
    };
}
