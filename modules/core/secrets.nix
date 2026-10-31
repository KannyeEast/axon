# One encrypted file per host. The SSH host key is the age identity, so there is no
# key file to lose. The user's private key is itself a secret, which lets the user
# edit secrets.json without any extra key material.
{ inputs, lib, ... }:
{
  flake.modules.nixos.core =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host user;
      file = host.dir + "/secrets.json";
      home = "/home/${user.name}";
    in
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      options.axon.secrets = lib.mkOption {
        type = lib.types.raw;
        readOnly = true;
        default = removeAttrs (builtins.fromJSON (builtins.readFile file)) [ "sops" ];
        defaultText = "the key structure of secrets.json";
        description = ''
          The shape of secrets.json. sops encrypts values, not keys, so evaluation can see
          which secrets exist. Read it for data (which networks, which backup targets),
          never to decide whether something is enabled.
        '';
      };

      config = {
        sops = {
          defaultSopsFile = file;
          # JSON is YAML; sops-nix's JSON reader rejects nested keys these files use
          defaultSopsFormat = "yaml";
          validateSopsFiles = false;
          age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];

          secrets.user-privatekey = {
            path = "${home}/.ssh/id_ed25519";
            owner = user.name;
            mode = "0600";
          };
        };

        environment.sessionVariables.SOPS_AGE_KEY_CMD = "ssh-to-age -private-key -i ${home}/.ssh/id_ed25519";
        environment.systemPackages = [
          pkgs.sops
          pkgs.ssh-to-age
        ];
      };
    };
}
