# Syncthing at sync.<domain>: folders between cluster members, shared as cluster.toml [sync] says.
# Reach: tailnet, the gateway's login.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  axon.schema.sync = {
    options.sync.id = mkOption {
      type = types.strMatching "[A-Z0-9]{7}(-[A-Z0-9]{7}){7}";
      description = "This host's Syncthing device id, generated at install.";
    };
  };

  flake.modules.nixos.sync =
    { config, ... }:
    let
      inherit (config.axon)
        cluster
        home
        host
        user
        volumes
        ;
      peerPort = 22000;

      folders = lib.attrNames (lib.filterAttrs (_: members: lib.elem host.name members) cluster.sync);
      peersOf = folder: lib.remove host.name cluster.sync.${folder};
      peers = lib.unique (lib.concatLists (map peersOf folders));

      device =
        peer:
        if cluster.hosts ? ${peer} then
          {
            id =
              cluster.hosts.${peer}.sync.id
                or (throw "cluster.toml: ${peer} shares a folder but its host.toml doesn't list the sync feature");
            addresses = [ "tcp://${peer}:${toString peerPort}" ];
          }
        else if (cluster.external.${peer}.sync or null) != null then
          { id = cluster.external.${peer}.sync; }
        else
          throw "cluster.toml: ${peer} shares a folder but has no syncthing id; give [external.${peer}] a sync id";

      pathOf = folder: volumes.${folder} or "${home}/${folder}";
      onVolumes = lib.filter (folder: volumes ? ${folder}) folders;
    in
    {
      # ── service ────────
      services.syncthing = {
        enable = true;
        user = user.name;
        dataDir = home;
        configDir = "/var/lib/syncthing";
        settings = {
          options = {
            globalAnnounceEnabled = false; # the tailnet carries everything
            relaysEnabled = false;
            urAccepted = -1;
          };
          # behind the gateway its host check rejects sync.<domain>; it still listens on localhost.
          # Elsewhere the check stays: it keeps websites out of the local UI (DNS rebinding)
          gui = {
            insecureSkipHostcheck = config.axon.routed;
            # no own login (one set in its UI is cleared): the gateway's login or localhost guard it
            user = "";
            password = "";
          };
          devices = lib.genAttrs peers device;
          folders = lib.genAttrs folders (folder: {
            path = pathOf folder;
            devices = peersOf folder;
            # deletions and damage sync like good changes; the receiver keeps the old copy 30 days
            versioning = {
              type = "staggered";
              params.maxAge = "2592000";
            };
          });
        };
      };

      # ── units ────────
      # the level as a syslog prefix, which journald reads; INF/WRN in the text count as info
      systemd.services.syncthing.environment.STLOGFORMATLEVELSYSLOG = "true";

      # ── data ────────
      # a volume mounts as root, so its folder is handed to the user
      axon.folders = lib.genAttrs (map pathOf onVolumes) (_: {
        user = user.name;
        group = "users";
        mode = "0700";
        units = [ "syncthing" ];
      });

      axon.persist.state.directories = [
        {
          directory = "/var/lib/syncthing";
          user = user.name;
          group = "users";
          mode = "0700";
        }
      ];

      # ── contracts ────────
      axon.overlay.tcpPorts = [ peerPort ];

      # ── registration ────────
      axon.services.sync = {
        units = [
          "syncthing"
          "syncthing-init"
        ];
        route.port = 8384;
        dashboard = {
          name = "Syncthing";
          group = "Files";
          description = "Folders between machines";
          icon = "syncthing.svg";
          widget = {
            type = "syncthing";
            highlight = {
              # "1 / 2", devices connected out of all: amber while the two differ
              connected.string = {
                level = "warn";
                when = "regex";
                value = "^(\\d+) / (?!\\1$)";
              };
              errors.numeric = {
                level = "warn";
                when = "gt";
                value = 0;
              };
            };
          };
          key = true;
        };
        backup.paths = [ "/var/lib/syncthing" ] ++ map pathOf onVolumes;
      };
    };
}
