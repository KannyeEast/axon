# Hardware is a generated report, not configuration. nixpkgs' facter module turns
# hosts/<name>/facter.json into platform, firmware, microcode, initrd and driver settings.
# This file only adds the opinions the report leaves open on purpose, and derives
# axon.laptop and axon.nvidia from it for other modules.
{ lib, ... }:
let
  vendors = {
    intel = 32902; # 0x8086
    amd = 4098; # 0x1002
    nvidia = 4318; # 0x10de
  };

  # sysfs "0000:01:00.0" -> "PCI:1:0:0", the format hardware.nvidia.prime expects
  pciBusId =
    sysfs:
    "PCI:"
    + lib.concatMapStringsSep ":" (part: toString (lib.fromHexString part)) (
      lib.match "[[:xdigit:]]+:([[:xdigit:]]+):([[:xdigit:]]+)\\.([0-7])" sysfs
    );
in
{
  flake.modules.nixos.core =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host;
      report = config.hardware.facter.report;

      cards = report.hardware.graphics_card or [ ];
      cardsOf = vendor: lib.filter (card: (card.vendor.value or 0) == vendors.${vendor}) cards;
      has = vendor: cardsOf vendor != [ ];
      busId = vendor: pciBusId (lib.head (cardsOf vendor)).sysfs_bus_id;

      inherit (config.axon) laptop nvidia;
      hybrid = nvidia && (has "intel" || has "amd");
    in
    {
      options.axon = {
        laptop = lib.mkOption {
          type = lib.types.bool;
          readOnly = true;
          description = "Whether facter reports this machine as a laptop.";
        };
        nvidia = lib.mkOption {
          type = lib.types.bool;
          readOnly = true;
          description = "Whether this machine has an NVIDIA graphics card.";
        };
      };

      config = lib.mkMerge [
        {
          hardware.facter.reportPath = host.dir + "/facter.json";
          axon.laptop = (report.hardware.system.form_factor or "") == "laptop";
          axon.nvidia = has "nvidia";

          assertions = [
            {
              assertion = report ? system;
              message = "hosts/${host.name}/facter.json: missing or empty; generate it with nixos-facter";
            }
          ];
        }

        # hardware video decoding on Intel GPUs; facter enables graphics, not the VA-API driver
        (lib.mkIf (has "intel") {
          hardware.graphics.extraPackages = [
            pkgs.intel-media-driver
            pkgs.vpl-gpu-rt
          ];
          environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
        })

        (lib.mkIf nvidia {
          services.xserver.videoDrivers = [ "nvidia" ];
          hardware.nvidia.open = true;
        })

        (lib.mkIf hybrid {
          hardware.nvidia.prime = {
            offload.enable = true;
            offload.enableOffloadCmd = true;
            nvidiaBusId = busId "nvidia";
          }
          // lib.optionalAttrs (has "intel") { intelBusId = busId "intel"; }
          // lib.optionalAttrs (has "amd") { amdgpuBusId = busId "amd"; };
        })

        (lib.mkIf laptop {
          services.power-profiles-daemon.enable = true;
        })
      ];
    };
}
