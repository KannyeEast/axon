# One person per host. Who may log in comes from cluster.toml [ssh], declared once,
# on the side that holds the key.
{ lib, ... }:
let
  inherit (lib) attrNames elem filterAttrs;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) host user cluster;

      inbound = attrNames (filterAttrs (_: targets: elem host.name targets) cluster.ssh);

      keyOf =
        member:
        if cluster.hosts ? ${member} then
          cluster.hosts.${member}.user.key
        else if (cluster.external.${member}.key or null) != null then
          cluster.external.${member}.key
        else
          throw "cluster.toml: ${member} logs in via [ssh] but has no key; give [external.${member}] a key";

      keys = map keyOf inbound;
    in
    {
      assertions = [
        {
          # a server nobody can reach is a server you have to walk to
          assertion = host.class != "server" || keys != [ ];
          message = "cluster.toml: no member of [ssh] may log in to ${host.name}, and a server needs one";
        }
      ];

      users.mutableUsers = false;
      users.users.${user.name} = {
        isNormalUser = true;
        uid = 1000; # fixed, so an existing /home keeps its owner across reinstalls
        extraGroups = [
          "wheel"
          "networkmanager"
        ];
        hashedPasswordFile = config.sops.secrets.user-password.path;
        openssh.authorizedKeys.keys = keys;
      };

      users.users.root.openssh.authorizedKeys.keys = keys;

      sops.secrets.user-password.neededForUsers = true;
      security.sudo.extraConfig = "Defaults lecture=never";
    };
}
