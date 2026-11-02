# Hardware is a generated report, not configuration. nixpkgs' facter module turns
# hosts/<name>/facter.json into platform, firmware, microcode, initrd and driver settings.
# This file only adds the opinions the report leaves open on purpose.
{ lib, ... }:
let
  inherit (lib)
    concatMapStringsSep
    filter
    fromHexString
    head
    mkIf
    mkMerge
    optionalAttrs
    ;

  vendors = {
    intel = 32902; # 0x8086
    amd = 4098; # 0x1002
    nvidia = 4318; # 0x10de
  };

  # sysfs "0000:01:00.0" -> "PCI:1:0:0", the format hardware.nvidia.prime expects
  pciBusId =
    sysfs:
    "PCI:"
    + concatMapStringsSep ":" (part: toString (fromHexString part)) (
      builtins.match "[[:xdigit:]]+:([[:xdigit:]]+):([[:xdigit:]]+)\\.([0-7])" sysfs
    );
in
{
  flake.modules.nixos.core =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host;
      report = config.hardware.facter.report;

      cards = report.hardware.graphics_card or [ ];
      cardsOf = vendor: filter (card: (card.vendor.value or 0) == vendors.${vendor}) cards;
      has = vendor: cardsOf vendor != [ ];
      busId = vendor: pciBusId (head (cardsOf vendor)).sysfs_bus_id;

      nvidia = has "nvidia";
      hybrid = nvidia && (has "intel" || has "amd");
    in
    {
      config = mkMerge [
        {
          hardware.facter.reportPath = host.dir + "/facter.json";
          services.fstrim.enable = true;

          assertions = [
            {
              assertion = report ? system;
              message = "hosts/${host.name}/facter.json: missing or empty; generate it with nixos-facter";
            }
          ];
        }

        # hardware video decoding on Intel GPUs; facter enables graphics, not the VA-API driver
        (mkIf (has "intel") {
          hardware.graphics.extraPackages = [
            pkgs.intel-media-driver
            pkgs.vpl-gpu-rt
          ];
          environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
        })

        (mkIf nvidia {
          services.xserver.videoDrivers = [ "nvidia" ];
          hardware.nvidia = {
            open = true;
            modesetting.enable = true;
          };
        })

        (mkIf hybrid {
          hardware.nvidia.prime = {
            offload.enable = true;
            offload.enableOffloadCmd = true;
            nvidiaBusId = busId "nvidia";
          }
          // optionalAttrs (has "intel") { intelBusId = busId "intel"; }
          // optionalAttrs (has "amd") { amdgpuBusId = busId "amd"; };
        })

        (mkIf ((report.hardware.system.form_factor or "") == "laptop") {
          services.power-profiles-daemon.enable = true;
        })
      ];
    };
}
