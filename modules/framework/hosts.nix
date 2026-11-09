# Discovers hosts/<name>/host.toml and turns each into nixosConfigurations.<name>.
#
# Two passes, both before any NixOS evaluation:
#   1. class, features and hardware.quirks are read raw, because they decide what gets
#      imported and imports cannot depend on config
#   2. every host.toml is checked against the schema pieces of core, its class and its
#      features, and cluster.toml against the cluster schema; defaults are filled in
# Each host then receives its own checked tables as config.axon.<table>, and every
# host's checked tables as config.axon.cluster.hosts.
{
  inputs,
  config,
  lib,
  ...
}:
let
  inherit (lib)
    attrNames
    attrValues
    concatLists
    concatStringsSep
    elem
    evalModules
    filter
    filterAttrs
    genAttrs
    mapAttrs
    mkOption
    pathExists
    readDir
    subtractLists
    types
    unique
    ;

  inherit (config.flake.modules) nixos homeManager;
  inherit (config.axon) features schema clusterSchema;
  classes = attrNames config.axon.classes;

  root = ../..;
  hostsDir = root + "/hosts";
  clusterFile = root + "/cluster.toml";

  # a folder starting with _ is kept for reference and never built (e.g. hosts/_old)
  isHost =
    name: type:
    type == "directory" && !lib.hasPrefix "_" name && pathExists (hostsDir + "/${name}/host.toml");
  raw = genAttrs (attrNames (filterAttrs isHost (readDir hostsDir))) (
    name: lib.importTOML (hostsDir + "/${name}/host.toml")
  );

  list = concatStringsSep ", ";

  # [ "core" <class> <features…> ], failing early with the file to fix
  bundles =
    name: data:
    let
      where = "hosts/${name}/host.toml";
      class = data.host.class or (throw "${where}: host.class is required (${list classes})");
      wanted = data.host.features or [ ];

      checkFeature =
        feature:
        let
          meta =
            features.${feature}
              or (throw "${where}: unknown feature '${feature}' (known: ${list (attrNames features)})");
          missing = filter (required: !elem required wanted) meta.requires;
        in
        if !elem class meta.classes then
          throw "${where}: feature '${feature}' runs on ${list meta.classes} hosts, not ${class}"
        else if missing != [ ] then
          throw "${where}: feature '${feature}' requires ${list missing}"
        else
          feature;
    in
    if !elem class classes then
      throw "${where}: class '${class}' is not one of ${list classes}"
    else
      [
        "core"
        class
      ]
      ++ map checkFeature wanted;

  # host.toml against the schema pieces of its bundles
  check =
    name: data:
    removeAttrs
      (evalModules {
        modules =
          map (bundle: schema.${bundle}) (filter (bundle: schema ? ${bundle}) (bundles name data))
          ++ [
            {
              _file = hostsDir + "/${name}/host.toml";
              config = data;
            }
            {
              _file = "modules/framework/hosts.nix";
              config.host = {
                inherit name;
                dir = hostsDir + "/${name}";
              };
            }
          ];
      }).config
      [ "_module" ];

  hosts = mapAttrs check raw;

  # cluster.toml against its schema. Every name a relation mentions should be a host or
  # [external]; one that isn't yet (a host not installed so far) is left out with a warning,
  # so a cluster can be brought up one machine at a time.
  cluster =
    let
      data = if pathExists clusterFile then lib.importTOML clusterFile else { };
      checked =
        removeAttrs
          (evalModules {
            modules = [
              clusterSchema
              {
                _file = clusterFile;
                config = data;
              }
            ];
          }).config
          [ "_module" ];
      members = attrNames hosts ++ attrNames checked.external;
      known = name: elem name members;

      mentioned = unique (
        attrNames checked.ssh
        ++ concatLists (attrValues checked.ssh)
        ++ concatLists (attrValues checked.sync)
      );
      strangers = subtractLists members mentioned;

      present = checked // {
        ssh = mapAttrs (_: filter known) (filterAttrs (name: _: known name) checked.ssh);
        sync = mapAttrs (_: filter known) checked.sync;
        inherit hosts;
      };
    in
    if strangers == [ ] then
      present
    else
      lib.warn "cluster.toml: ${list strangers} is neither a host nor listed under [external]; left out until it exists" present;

  quirk =
    name: module:
    inputs.nixos-hardware.nixosModules.${module}
      or (throw "hosts/${name}/host.toml: unknown hardware quirk '${module}' (see nixos-hardware's flake outputs)");

  # config.axon.<table> for every table of this host, plus config.axon.cluster
  data =
    name:
    let
      values = hosts.${name} // {
        inherit cluster;
      };
    in
    {
      _file = "modules/framework/hosts.nix";
      options.axon = mapAttrs (
        _: _:
        mkOption {
          type = types.raw;
          readOnly = true;
        }
      ) values;
      config.axon = values;
    };

  mkHost =
    name: toml:
    let
      names = bundles name toml;
      # a bundle may have only a nixos half or only a homeManager half
      select = set: map (bundle: set.${bundle}) (filter (bundle: set ? ${bundle}) names);
    in
    inputs.nixpkgs.lib.nixosSystem {
      modules =
        select nixos
        ++ map (quirk name) (toml.hardware.quirks or [ ])
        ++ [
          (data name)
          { home-manager.sharedModules = select homeManager; }
        ];
    };
in
{
  flake.nixosConfigurations = mapAttrs mkHost raw;
}
