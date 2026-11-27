# `session` lends the current folder to a server that lists dev, where Claude works on in tmux
# while Mutagen keeps the folder in sync; its usage is at the top of _session.sh.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      inherit (config.axon) cluster host hostsWith;
      servers = lib.attrNames (
        lib.filterAttrs (
          name: data: data.host.class == "server" && lib.elem name (cluster.ssh.${host.name} or [ ])
        ) (hostsWith "dev")
      );
      # build output and caches stay on each machine; a synced git lock looks stale on the other
      ignored = [
        "result"
        "result-*"
        "target"
        "node_modules"
        ".direnv"
        ".git/*.lock"
        ".git/**/*.lock"
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
        runtimeEnv = {
          DEFAULT_SERVER = lib.head servers;
          IGNORED = ignored;
        };
        text = builtins.readFile ./_session.sh;
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
          ExecStart = "${lib.getExe' pkgs.mutagen "mutagen"} daemon run";
          Restart = "on-failure";
        };
      };
    };
}
