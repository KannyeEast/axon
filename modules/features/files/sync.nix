# Syncthing between cluster members. Its settings table is [sync] in host.toml, which only
# exists where the files feature is listed, so a stray [sync] table is an error.
# Who shares what is a relation, declared once in cluster.toml [sync]. A folder that is
# also a cluster volume on this host lives on that volume, everywhere else in ~/<folder>.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatLists
    elem
    filter
    filterAttrs
    genAttrs
    head
    mkOption
    remove
    splitString
    types
    unique
    ;
in
{
  axon.schema.files = {
    options.sync.id = mkOption {
      type = types.strMatching "[A-Z0-9]{7}(-[A-Z0-9]{7}){7}";
      description = "This host's Syncthing device id, generated at install.";
    };
  };

  flake.modules.nixos.files =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host user cluster;
      home = "/home/${user.name}";

      # folders this host is a member of, and everyone it shares them with
      folders = attrNames (filterAttrs (_: members: elem host.name members) cluster.sync);
      peersOf = folder: remove host.name cluster.sync.${folder};
      peers = unique (concatLists (map peersOf folders));

      device =
        peer:
        if cluster.hosts ? ${peer} then
          {
            id =
              cluster.hosts.${peer}.sync.id
                or (throw "cluster.toml: ${peer} shares a folder but its host.toml doesn't list the files feature");
            # hosts reach each other by name over the tailnet
            addresses = [ "tcp://${peer}:22000" ];
          }
        else if (cluster.external.${peer}.sync or null) != null then
          { id = cluster.external.${peer}.sync; }
        else
          throw "cluster.toml: ${peer} shares a folder but has no syncthing id; give [external.${peer}] a sync id";

      # "node1:/srv/vault" -> "/srv/vault" when this host is node1
      volumeOn =
        folder:
        let
          parts = splitString ":" (cluster.volumes.${folder} or "");
        in
        if cluster.volumes ? ${folder} && head parts == host.name then
          lib.concatStringsSep ":" (lib.tail parts)
        else
          null;

      pathOf = folder: if volumeOn folder != null then volumeOn folder else "${home}/${folder}";
      onVolumes = filter (folder: volumeOn folder != null) folders;
    in
    {
      services.syncthing = {
        enable = true;
        user = user.name;
        dataDir = home;
        configDir = "/var/lib/syncthing";
        overrideDevices = true;
        overrideFolders = true;
        settings = {
          options = {
            globalAnnounceEnabled = false; # the tailnet carries everything
            relaysEnabled = false;
            urAccepted = -1;
          };
          # behind the gateway the UI is asked for as sync.<domain>, which its host check
          # rejects; it still only listens on localhost, and the gateway login is in front.
          # Elsewhere the check stays: it keeps websites out of the local UI (DNS rebinding).
          gui.insecureSkipHostcheck = elem "gateway" host.features;
          devices = genAttrs peers device;
          folders = genAttrs folders (folder: {
            path = pathOf folder;
            devices = peersOf folder;
          });
        };
      };

      # A folder on a volume needs that disk. Volumes mount with nofail, so without it Syncthing
      # would start against the bare mountpoint on the root filesystem. The folder is handed to
      # the user only once the disk is mounted (the volume itself is mounted as root).
      systemd.services.syncthing = lib.mkIf (onVolumes != [ ]) {
        unitConfig.RequiresMountsFor = map pathOf onVolumes;
        serviceConfig.ExecStartPre = map (
          folder: "+${pkgs.coreutils}/bin/install -d -o ${user.name} -g users -m 0700 ${pathOf folder}"
        ) onVolumes;
      };

      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
        22000
      ];

      axon.persist.directories = [
        {
          directory = "/var/lib/syncthing";
          user = user.name;
          group = "users";
          mode = "0700";
        }
      ];

      # producer side of the services contract; published everywhere, read only by a gateway
      axon.services.sync = {
        route.port = 8384;
        dashboard = {
          name = "Syncthing";
          group = "Files";
          description = "Folders between machines";
          icon = "syncthing.svg";
          widget.type = "syncthing";
          secrets.key = "dashboard/sync/key";
        };
        backup.paths = [ "/var/lib/syncthing" ] ++ map pathOf onVolumes;
      };
    };
}
