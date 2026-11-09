# Forgejo at git.<domain>: git repositories on the tailnet, with its own login and sign-up off.
# Without a gateway on this host it stays on localhost. Everything (repositories, SQLite
# database, dumps) lives on the data volume, or in /var/lib on a host without one. Git over SSH
# goes through the host's own sshd as forgejo@git.<domain>.
# The first account is created by hand after install:
#   sudo -u forgejo forgejo --work-path <state dir> admin user create --admin --username <name> --email <address> --random-password
# A nightly dump is what gets backed up.
{ lib, ... }:
{
  flake.modules.nixos.forge =
    { config, ... }:
    let
      inherit (config.axon)
        remotes
        routed
        services
        spaces
        ;
      cfg = config.services.forgejo;
      route = services.git.route;
      port = 3030;
      # the forges the repository is mirrored to, from cluster.toml [repo]
      mirrors = lib.unique (
        lib.mapAttrsToList (_: remote: lib.head (lib.match "https://([^/]+)/.*" remote.web)) (
          lib.filterAttrs (_: remote: !remote.origin && remote.web != null) remotes
        )
      );
    in
    {
      services.forgejo = {
        enable = true;
        stateDir = spaces.forgejo.path;
        dump.enable = true;
        settings = {
          server = {
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = port;
            DOMAIN = if routed then route.host else "localhost";
            ROOT_URL = if routed then "${route.url}/" else "http://localhost:${toString port}/";
          };
          service.DISABLE_REGISTRATION = true;
          session.COOKIE_SECURE = routed;
        };
      };

      # the admin command line
      environment.systemPackages = [ cfg.package ];

      # push mirrors connect over SSH as forgejo unless their address names a user, and forges
      # only take git; this way a mirror works however its address was entered. It holds for every
      # user on this host; git is the SSH login on every forge
      programs.ssh.extraConfig = lib.concatMapStrings (host: ''
        Host ${host}
          User git
      '') mirrors;

      axon.spaces.forgejo = {
        inherit (cfg) user group;
        units = [
          "forgejo"
          "forgejo-dump"
        ];
      };

      axon.services.git = {
        route = {
          inherit port;
          access = "open"; # Forgejo's own login
        };
        dashboard = {
          name = "Forgejo";
          group = "Code";
          description = "Git repositories";
          icon = "forgejo.svg";
        };
        backup.paths = [ cfg.dump.backupDir ];
      };
    };
}
