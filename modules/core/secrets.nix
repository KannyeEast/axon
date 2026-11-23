# One encrypted secrets.json per host, opened with the SSH host key as age identity: no key file
# to lose. The user's private key is a secret in it too, so editing needs no extra key material.
{ inputs, lib, ... }:
{
  flake.modules.nixos.core =
    { config, pkgs, ... }:
    let
      inherit (config.axon) home host user;
      file = host.dir + "/secrets.json";
      exists = lib.pathExists file;
    in
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      # ── contract ────────
      options.axon.secrets = lib.mkOption {
        type = lib.types.raw;
        readOnly = true;
        default = lib.optionalAttrs exists (removeAttrs (lib.importJSON file) [ "sops" ]);
        defaultText = "the key structure of secrets.json";
        description = ''
          The shape of secrets.json. sops encrypts values, not keys, so evaluation can see
          which secrets exist. Read it for data (which networks, which backup targets, which API keys);
          an extra that switches on with its secret reads axon.hasSecret. A hard need declares its
          sops.secrets, and evaluation lists what is missing.
        '';
      };

      options.axon.hasSecret = lib.mkOption {
        type = lib.types.functionTo lib.types.bool;
        readOnly = true;
        default = name: lib.hasAttrByPath (lib.splitString "/" name) config.axon.secrets;
        defaultText = "whether secrets.json holds the secret";
        description = "Whether secrets.json holds the secret of this name (area/name), for extras that switch on with their secret.";
      };

      config = {
        # ── settings ────────
        sops = {
          defaultSopsFile = file;
          # JSON is YAML; sops-nix's JSON reader rejects nested keys these files use
          defaultSopsFormat = "yaml";
          validateSopsFiles = false;
        };
        environment.sessionVariables.SOPS_AGE_KEY_CMD = "ssh-to-age -private-key -i ${home}/.ssh/id_ed25519";
        environment.systemPackages = [
          pkgs.sops
          pkgs.ssh-to-age
        ];

        # ── secrets ────────
        sops.secrets."user/private-key" = {
          path = "${home}/.ssh/id_ed25519";
          owner = user.name;
          mode = "0600";
        };

        # ── checks ────────
        # sops-nix finds a missing key only at boot and then installs none of the host's secrets
        # (Tailscale's among them), so evaluation, and install.sh before it wipes, fails first
        assertions =
          let
            ours = lib.filter (secret: secret.sopsFile == file && secret.key != "") (
              lib.attrValues config.sops.secrets
            );
            missing = lib.filter (secret: !config.axon.hasSecret secret.key) ours;
          in
          [
            {
              assertion = exists;
              message = "hosts/${host.name}/secrets.json: missing; run install.sh for this host";
            }
            {
              assertion = !exists || missing == [ ];
              message = "hosts/${host.name}/secrets.json: missing ${
                lib.concatMapStringsSep ", " (secret: "'${secret.key}'") missing
              }; add them with `just secrets ${host.name}` (a/b is {\"a\": {\"b\": …}})";
            }
          ];
      };
    };
}
