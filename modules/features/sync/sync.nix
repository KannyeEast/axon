# Syncthing between cluster members. Its settings table is [sync] in host.toml, which only
# exists where the sync feature is listed, so a stray [sync] table is an error.
# Who shares what is a relation, declared once in cluster.toml [sync]. A folder named like
# one of this host's volumes lives on that volume, everywhere else in ~/<folder>.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatLists
    elem
    filter
    filterAttrs
    genAttrs
    mkOption
    remove
    types
    unique
    ;
in
{
  axon.schema.sync = {
    options.sync.id = mkOption {
      type = types.strMatching "[A-Z0-9]{7}(-[A-Z0-9]{7}){7}";
      description = "This host's Syncthing device id, generated at install.";
    };
  };

  flake.modules.nixos.sync =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        home
        host
        user
        cluster
        volumes
        ;
      peerPort = 22000;

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
                or (throw "cluster.toml: ${peer} shares a folder but its host.toml doesn't list the sync feature");
            # hosts reach each other by name over the tailnet
            addresses = [ "tcp://${peer}:${toString peerPort}" ];
          }
        else if (cluster.external.${peer}.sync or null) != null then
          { id = cluster.external.${peer}.sync; }
        else
          throw "cluster.toml: ${peer} shares a folder but has no syncthing id; give [external.${peer}] a sync id";

      pathOf = folder: volumes.${folder} or "${home}/${folder}";
      onVolumes = filter (folder: volumes ? ${folder}) folders;
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
          gui.insecureSkipHostcheck = config.axon.routed;
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
          folder:
          "+${lib.getExe' pkgs.coreutils "install"} -d -o ${user.name} -g users -m 0700 ${pathOf folder}"
        ) onVolumes;
      };

      axon.overlay.tcpPorts = [ peerPort ];

      axon.persist.directories = [
        {
          directory = "/var/lib/syncthing";
          user = user.name;
          group = "users";
          mode = "0700";
        }
      ];

      # producer side of the services contract: a gateway reads the route, backup the paths
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
