# Forgejo at git.<domain>: git repositories, also over SSH as forgejo@git.<domain>.
# Reach: tailnet, its own login with sign-up off; axon.sso's for its admins once linked.
# In its UI only: users, tokens, push mirrors and Actions secrets, in its database, dumped nightly.
# By hand: `sudo -u forgejo forgejo --work-path <state dir> admin user create --admin --username <name> --email <address> --random-password`.
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
      # attachments, avatars, LFS objects, packages
      data = "${cfg.stateDir}/data";
      mirrors = lib.unique (
        lib.mapAttrsToList (_: remote: remote.host) (lib.filterAttrs (_: remote: remote.mirror) remotes)
      );
    in
    {
      services.forgejo = {
        enable = true;
        stateDir = spaces.forgejo.path;
        database.type = "postgres";
        settings = {
          server = {
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = port;
            DOMAIN = route.name;
            ROOT_URL = "${route.origin}/";
          };
          service.DISABLE_REGISTRATION = true;
          session.COOKIE_SECURE = routed;
          log = {
            # no router log, a line per request; errors still reach the default log
            LOGGER_ROUTER_MODE = "";
            # at info it logs a database ping for every health check
            LEVEL = "Warn";
          };
        };
      };

      axon.databases = [ cfg.database.name ];

      # the login source, made or updated before every start; a failure leaves it as it was. The
      # secret is on the command line while it runs: the command takes it no other way
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
        service = "git";
        landing = "${route.url}/user/oauth2/${source}";
        redirects = [ "${route.url}/user/oauth2/${source}/callback" ];
        group = "admins";
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
        units = [ "forgejo" ];
      };

      axon.services.git = {
        units = [
          "forgejo"
          "forgejo-secrets"
        ];
        route = {
          inherit port;
          gate = false;
          health = "/api/healthz";
        };
        dashboard = {
          name = "Forgejo";
          group = "Infrastructure";
          description = "Git repositories";
          icon = "forgejo.svg";
          space = "forgejo";
          # Gitea's API; the token reads repository, issue, notification and user, with access "All"
          # (not "Public only"), which n8n's Mirror check needs to list push mirrors
          widget.type = "gitea";
          key = true;
        };
        # the custom dir holds the key that encrypts secrets in the database
        backup = {
          paths = [
            cfg.repositoryRoot
            cfg.customDir
            data
          ];
          # rebuilt by Forgejo
          exclude = [
            "${data}/indexers"
            "${data}/repo-archive"
          ];
        };
      };
    };
}
