# Every Redis server a module starts: logs at warning (at notice it logs each snapshot, every few
# minutes) and keeps its data in appdata.
{ lib, ... }:
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      servers = lib.filterAttrs (_: server: server.enable) config.services.redis.servers;
    in
    {
      # ── settings ────────
      # a submodule declared again merges into the module's own, so this reaches every server
      options.services.redis.servers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule { config.logLevel = lib.mkDefault "warning"; });
      };

      # ── data ────────
      config.axon.persist.state.directories = lib.mapAttrsToList (
        name: _: "/var/lib/redis${lib.optionalString (name != "") "-${name}"}"
      ) servers;
    };
}
