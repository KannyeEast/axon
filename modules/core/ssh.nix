{ lib, ... }:
let
  # forges are trusted from the first boot, so a fresh install can clone over ssh
  forges = {
    "github.com" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    "codeberg.org" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVIC02vnjFyL+I4RHfvIGNtOgJMe769VTF1VR4EB3ZB";
    "gitlab.com" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf";
  };
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) cluster;
    in
    {
      services.openssh = {
        enable = true;
        openFirewall = true;
        settings = {
          # deliberate: a lost key must not lock you out of a machine you can't walk to
          PasswordAuthentication = true;
          KbdInteractiveAuthentication = true;
        };
        # the host key is the machine's identity: it decrypts secrets.json, so it lives in /persist
        hostKeys = [
          {
            path = "/persist/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
      };

      # losing the host key means losing access to secrets.json; offer it to whatever backs up
      axon.services.ssh.backup.paths = [ "/persist/etc/ssh" ];

      # every host in the cluster trusts every other host by its recorded key
      programs.ssh.knownHosts =
        lib.mapAttrs (_: publicKey: { inherit publicKey; }) forges
        // lib.mapAttrs (name: data: {
          hostNames = [
            name
            "${name}.local"
          ];
          publicKey = data.host.key;
        }) cluster.hosts;
    };
}
