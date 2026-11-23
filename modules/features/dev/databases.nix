# pgweb at databases.<domain>: a read-only view of every database the host keeps (axon.databases).
# Reach: tailnet, the gateway's login.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      inherit (config.axon) databases host;
      port = 8083;
      # lib/pq sorts a URL's settings: the socket wins only over a host sorting before "/" ("-");
      # without a host, switching databases in the UI puts the database's name there
      bookmarks = pkgs.writeTextDir "${host.name}.toml" ''
        url = "postgres://pgweb@-/${lib.head databases}?host=/run/postgresql"
      '';
      # the host's own, without Postgres's built-in databases
      own = ''{host="${host.name}",datname!~"postgres|template.*"}'';
    in
    lib.mkIf (databases != [ ]) {
      # ── service ────────
      # named like the unit's dynamic user, so peer authentication lets it in
      services.postgresql.ensureUsers = [ { name = "pgweb"; } ];

      # ── units ────────
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
          # only the bookmark connects; --lock-session would also stop switching databases.
          # warn logs every 4xx, and the start page's check tries HEAD first, which gets a 404
          ExecStart = "${lib.getExe pkgs.pgweb} --bind=127.0.0.1 --listen=${toString port} --bookmarks-dir=${bookmarks} --bookmarks-only --bookmark=${host.name} --readonly --log-level=error";
        };
      };

      # ── registration ────────
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
