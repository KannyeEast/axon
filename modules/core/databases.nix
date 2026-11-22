# Contract: axon.databases. The Postgres databases this host's services keep; each service creates
# its own through its module (ensureDatabases or the module's own option). With any listed, the
# host runs its own Postgres (no database is shared between hosts) and dumps each one nightly to
# the data volume, where a host has one: a dump next to its database is lost with it.
{ lib, ... }:
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) databases volumes;
      dumps = "${volumes.data or "/var/backup"}/postgresql";
    in
    {
      options.axon.databases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Names of the Postgres databases this host's services keep, each dumped nightly.";
      };

      config = lib.mkIf (databases != [ ]) {
        services.postgresql = {
          enable = true;
          # on by default: two lines for each checkpoint, every few minutes
          settings.log_checkpoints = false;
        };

        services.postgresqlBackup = {
          enable = true;
          location = dumps;
          inherit databases;
        };

        # the dumps live on a data disk that may be missing at boot (nofail): never write to root instead
        systemd.services = lib.genAttrs (map (name: "postgresqlBackup-${name}") databases) (_: {
          unitConfig.RequiresMountsFor = [ dumps ];
        });

        axon.persist.state.directories = [
          {
            directory = "/var/lib/postgresql";
            user = "postgres";
            group = "postgres";
            mode = "0750";
          }
        ]
        ++ lib.optional (!volumes ? data) dumps;

        axon.services.database = {
          units = [
            "postgresql"
            "postgresql-setup"
          ]
          ++ map (name: "postgresqlBackup-${name}") databases;
          backup.paths = [ dumps ];
        };
      };
    };
}
