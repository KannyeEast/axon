# Contract: axon.folders. Folders services need to exist, by path, with owner and mode. Features
# add them with the units that use them; core makes each once its disk is mounted, as tmpfiles may
# run before a data disk is, and starts those units after it. Empty, nothing is made.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  flake.modules.nixos.core =
    {
      config,
      pkgs,
      utils,
      ...
    }:
    let
      inherit (config.axon) folders;
      install = lib.getExe' pkgs.coreutils "install";
      unitOf = path: "folder-${utils.escapeSystemdPath path}";
    in
    {
      options.axon.folders = mkOption {
        default = { };
        description = "Folders services need, by path: made with owner and mode once their disk is mounted.";
        type = types.attrsOf (
          types.submodule {
            options = {
              user = mkOption {
                type = types.str;
                description = "Owner of the folder; every entry for the path must name the same.";
              };
              group = mkOption {
                type = types.str;
                description = "Group of the folder; every entry for the path must name the same.";
              };
              mode = mkOption {
                type = types.strMatching "[0-7]{4}";
                description = "Mode of the folder, e.g. 2775; every entry for the path must name the same.";
              };
              units = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "systemd services that use it: they start after it exists and wait for its disk.";
              };
            };
          }
        );
      };

      config.systemd.services = lib.mkMerge (
        [
          (lib.mapAttrs' (
            path: folder:
            lib.nameValuePair (unitOf path) {
              description = "Folder ${path}";
              # also for a folder no unit lists, which then still exists after boot
              wantedBy = [ "multi-user.target" ];
              # the data disk may be missing at boot (nofail): never write to root instead
              unitConfig.RequiresMountsFor = [ path ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${install} -d -o ${folder.user} -g ${folder.group} -m ${folder.mode} ${path}";
              };
            }
          ) folders)
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (
            path: folder:
            map (unit: {
              ${unit} = {
                requires = [ "${unitOf path}.service" ];
                after = [ "${unitOf path}.service" ];
                unitConfig.RequiresMountsFor = [ path ];
              };
            }) folder.units
          ) folders
        )
      );
    };
}
