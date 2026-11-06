# One encrypted file per host. The SSH host key is the age identity, so there is no
# key file to lose. The user's private key is itself a secret, which lets the user
# edit secrets.json without any extra key material.
{ inputs, lib, ... }:
{
  flake.modules.nixos.core =
    { config, pkgs, ... }:
    let
      inherit (config.axon) home host user;
      file = host.dir + "/secrets.json";
    in
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      options.axon.secrets = lib.mkOption {
        type = lib.types.raw;
        readOnly = true;
        default = removeAttrs (lib.fromJSON (lib.readFile file)) [ "sops" ];
        defaultText = "the key structure of secrets.json";
        description = ''
          The shape of secrets.json. sops encrypts values, not keys, so evaluation can see
          which secrets exist. Read it for data (which networks, which backup targets),
          never to decide whether something is enabled.
        '';
      };

      config = {
        # sops-nix finds a missing key only at boot, and then installs none of the host's
        # secrets (the Tailscale key among them). Every secret a module declares from this
        # file must exist here, so the evaluation, and install.sh before it wipes, fails first.
        assertions =
          let
            ours = lib.filter (secret: secret.sopsFile == file && secret.key != "") (
              lib.attrValues config.sops.secrets
            );
            missing = lib.filter (
              secret: !lib.hasAttrByPath (lib.splitString "/" secret.key) config.axon.secrets
            ) ours;
          in
          [
            {
              assertion = missing == [ ];
              message = "hosts/${host.name}/secrets.json: missing ${
                lib.concatMapStringsSep ", " (secret: "'${secret.key}'") missing
              }; add them with `just secrets ${host.name}` (a/b is {\"a\": {\"b\": …}})";
            }
          ];

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
