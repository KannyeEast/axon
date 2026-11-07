# git identity and signing come from host.toml; everything else about git is taste and
# lives in dotfiles (.config/git/config).
{
  flake.modules.homeManager.dev =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    let
      inherit (osConfig.axon) user cluster;

      # every user key in the cluster may sign; allowed_signers wants "<principal> <type> <key>"
      strip = key: lib.concatStringsSep " " (lib.take 2 (lib.splitString " " key));
      keys = lib.unique (
        map strip (
          lib.mapAttrsToList (_: data: data.user.key) cluster.hosts
          ++ lib.filter (key: key != null) (lib.mapAttrsToList (_: member: member.key) cluster.external)
        )
      );
    in
    {
      home.file.".ssh/allowed_signers".text = lib.concatMapStrings (key: "${user.email} ${key}\n") keys;

      programs.git = {
        enable = true;
        settings = {
          user = {
            inherit (user) name email;
          };
          gpg.ssh.allowedSignersFile = "${config.home.homeDirectory}/.ssh/allowed_signers";
        };
        signing = {
          format = "ssh";
          key = "${config.home.homeDirectory}/.ssh/id_ed25519";
          signByDefault = true;
        };
      };
    };
}
