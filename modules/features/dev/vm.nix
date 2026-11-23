# Virtual machines for other operating systems (virt-manager), on desktops.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      # ── service ────────
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

      # ── program ────────
      programs.virt-manager.enable = true;

      # ── system ────────
      users.users.${config.axon.user.name}.extraGroups = [ "libvirtd" ];
      # guests on libvirt's NAT bridge get DHCP and DNS from the host; the firewall drops them otherwise
      networking.firewall.trustedInterfaces = [ "virbr0" ];

      # ── data ────────
      axon.persist.state.directories = [ "/var/lib/libvirt" ];
    };
}
