# Docker, rootful, for the services a server runs as containers (virtualisation.oci-containers).
# No person's account joins the docker group: it is root by another name. A published port opens
# on 127.0.0.1 only, since Docker's own iptables rules come before the host firewall; the gateway
# proxies. Every image is pinned to a digest, so it changes only through a Renovate pull request.
{ lib, ... }:
{
  flake.modules.nixos.server =
    { config, ... }:
    let
      option = name: "virtualisation.oci-containers.containers.${name}";
      checks =
        name: container:
        map (port: {
          assertion = lib.hasPrefix "127.0.0.1:" port;
          message = "${option name}.ports: ${port} is published beyond this host; bind it to 127.0.0.1 (127.0.0.1:<host port>:<container port>)";
        }) container.ports
        ++ [
          {
            # images built by Nix have no registry digest
            assertion =
              container.imageFile != null
              || container.imageStream != null
              || lib.hasInfix "@sha256:" container.image;
            message = "${option name}.image: ${container.image} has no digest; pin it as <name>:<tag>@sha256:<digest> (skopeo inspect docker://<name>:<tag> shows it)";
          }
        ];
    in
    {
      virtualisation.docker = {
        enable = true;
        # where a port published without an address binds
        daemon.settings.ip = "127.0.0.1";
        autoPrune = {
          enable = true;
          # also tagged images no container uses, such as the versions an update replaced
          flags = [ "--all" ];
        };
      };
      virtualisation.oci-containers.backend = "docker";

      axon.persist.directories = [ "/var/lib/docker" ];

      assertions = lib.concatLists (
        lib.mapAttrsToList checks config.virtualisation.oci-containers.containers
      );
    };
}
