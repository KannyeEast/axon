# Virtual machines for other operating systems (virt-manager), on desktops.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      virtualisation.libvirtd = {
        enable = true;
        onBoot = "ignore";
        # a guest with a virtiofs share cannot be restored from a saved state
        onShutdown = "shutdown";
        qemu = {
          runAsRoot = false;
          swtpm.enable = true;
          vhostUserPackages = [ pkgs.virtiofsd ];
        };
      };
      programs.virt-manager.enable = true;

      users.users.${config.axon.user.name}.extraGroups = [ "libvirtd" ];

      axon.persist.directories = [ "/var/lib/libvirt" ];

      networking.firewall.trustedInterfaces = [ "virbr0" ];
    };
}
