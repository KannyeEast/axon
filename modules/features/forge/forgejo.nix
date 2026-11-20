# Forgejo at git.<domain>: git repositories on the tailnet, its own login, sign-up off. Without a
# gateway on this host it stays on localhost. Repositories, SQLite database and dumps live on the
# data volume (or in /var/lib without one); the nightly dump is what gets backed up. Git over SSH
# goes through the host's own sshd as forgejo@git.<domain>. First account by hand after install:
#   sudo -u forgejo forgejo --work-path <state dir> admin user create --admin --username <name> --email <address> --random-password
# With a login provider (axon.sso) its admins log in there too: the first time, Forgejo asks for the
# local password once to link the two; nobody signs up through it, and the password form stays.
{ lib, ... }:
{
  flake.modules.nixos.forge =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        remotes
        routed
        services
        spaces
        sso
        ;
      cfg = config.services.forgejo;
      client = sso.clients.forgejo;
      route = services.git.route;
      source = "Kanidm";
      port = 3030;
      # the forges the repository is mirrored to, from cluster.toml [repo]
      mirrors = lib.unique (
        lib.mapAttrsToList (_: remote: remote.host) (lib.filterAttrs (_: remote: remote.mirror) remotes)
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
            DOMAIN = route.name;
            ROOT_URL = "${route.origin}/";
          };
          service.DISABLE_REGISTRATION = true;
          session.COOKIE_SECURE = routed;
        };
      };

      # the login source, made or updated before every start; Forgejo keeps it in its database.
      # Making it fetches the provider's discovery document; any failure leaves the source as it
      # was and Forgejo starts anyway. The secret is on the command line for the moment it runs: the
      # command takes it no other way
      systemd.services.forgejo = lib.mkIf (sso.provider != null) {
        # the client's discovery document only exists once the provider made it
        after = lib.optional (sso.unit != null) sso.unit;
        path = [ pkgs.gawk ];
        preStart = lib.mkAfter ''
          login_source() {
            local secret id
            secret=$(<${client.secret}) || return
            id=$(forgejo admin auth list | awk '$2 == "${source}" { print $1 }')
            local args=(
              --name ${source}
              --provider openidConnect
              --key ${client.id}
              --secret "$secret"
              --auto-discover-url ${client.issuer}/.well-known/openid-configuration
              --scopes profile
              --scopes email
            )
            if [ -n "$id" ]; then
              forgejo admin auth update-oauth --id "$id" "''${args[@]}"
            else
              forgejo admin auth add-oauth "''${args[@]}"
            fi
          }
          login_source || echo "login source ${source} left as it was" >&2
        '';
      };

      axon.sso.clients.forgejo = {
        displayName = "Forgejo";
        landing = "${route.url}/user/oauth2/${source}";
        redirects = [ "${route.url}/user/oauth2/${source}/callback" ];
        group = "admins";
        inherit (services.git.dashboard) icon;
      };

      # the admin command line
      environment.systemPackages = [ cfg.package ];

      # push mirrors log in over SSH as forgejo unless their address names a user, and forges only
      # take git. It applies to every user on this host; git is the SSH login on every forge
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
        units = [
          "forgejo"
          "forgejo-dump"
          "forgejo-secrets"
        ];
        route.port = port;
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
