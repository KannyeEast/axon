# pgweb at databases.<domain> where the host keeps axon.databases: a read-only view of every one
# of them, tailnet only, behind the gateway's login. Its Postgres role, named like its unit's
# dynamic user so peer authentication lets it in, may read all data and change none. The tile
# shows the databases' size and connections, how long ago the oldest dump ran and whether Postgres
# is up, from Prometheus (metrics/exporters.nix).
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      inherit (config.axon) databases host;
      port = 8083;
      # lib/pq sorts a URL's settings and takes the last host: the query's socket directory wins
      # only over a URL host that sorts before "/", such as "-". Without a URL host, switching
      # databases in the UI would put the database's name there
      bookmarks = pkgs.writeTextDir "${host.name}.toml" ''
        url = "postgres://pgweb@-/${lib.head databases}?host=/run/postgresql"
      '';
      # the host's own, without Postgres's built-in databases
      own = ''{host="${host.name}",datname!~"postgres|template.*"}'';
    in
    lib.mkIf (databases != [ ]) {
      services.postgresql.ensureUsers = [ { name = "pgweb"; } ];
      # ensureUsers has no role memberships; reading isn't connecting, and Nextcloud's install takes
      # that right from everyone else on its database
      systemd.services.postgresql-setup.script = lib.mkAfter ''
        psql -tAc 'GRANT pg_read_all_data TO pgweb'
        ${lib.concatMapStrings (database: ''
          psql -tAc 'GRANT CONNECT ON DATABASE "${database}" TO pgweb'
        '') config.axon.databases}
      '';

      systemd.services.pgweb = {
        description = "Read-only view of the Postgres databases";
        wantedBy = [ "multi-user.target" ];
        requires = [ "postgresql.target" ];
        after = [ "postgresql.target" ];
        serviceConfig = {
          DynamicUser = true;
          Restart = "on-failure";
          # only the bookmark connects: no form to reach other servers, while --lock-session would
          # also stop switching databases. At info it logs every request, the status checks' too
          ExecStart = "${lib.getExe pkgs.pgweb} --bind=127.0.0.1 --listen=${toString port} --bookmarks-dir=${bookmarks} --bookmarks-only --bookmark=${host.name} --readonly --log-level=warn";
        };
      };

      axon.services.databases = {
        units = [ "pgweb" ];
        route.port = port;
        dashboard = {
          name = "Databases";
          group = "Infrastructure";
          description = "Postgres, read-only";
          icon = "postgres.svg";
          widget = {
            type = "prometheusmetric";
            metrics = [
              {
                label = "size";
                query = "sum(pg_database_size_bytes${own})";
                format.type = "bbytes";
              }
              {
                label = "connections";
                query = "sum(pg_stat_database_numbackends${own})";
              }
              # a dump's timer reports 0 until its first run
              {
                label = "since dump";
                query = ''time() - min(node_systemd_timer_last_trigger_seconds{host="${host.name}",name=~"postgresqlBackup-.+[.]timer"} > 0)'';
                format.type = "duration";
              }
              {
                label = "up";
                query = ''pg_up{host="${host.name}"}'';
              }
            ];
          };
        };
      };
    };
}
