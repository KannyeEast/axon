# nixpkgs' facter module turns hosts/<name>/facter.json into platform, firmware, microcode,
# initrd and driver settings. This file adds what the report leaves open and derives axon.laptop
# and axon.nvidia from it.
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
      reportFile = host.dir + "/facter.json";
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
          default = (report.hardware.system.form_factor or "") == "laptop";
          defaultText = "form_factor laptop in facter.json";
          description = "Whether facter reports this machine as a laptop.";
        };
        nvidia = lib.mkOption {
          type = lib.types.bool;
          readOnly = true;
          default = has "nvidia";
          defaultText = "an NVIDIA graphics card in facter.json";
          description = "Whether this machine has an NVIDIA graphics card.";
        };
      };

      config = lib.mkMerge [
        {
          # a throw, not an assertion: the platform comes from the report, so without a usable one
          # evaluation stops on nixpkgs.hostPlatform before assertions run
          hardware.facter.reportPath =
            if
              lib.pathExists reportFile && lib.readFile reportFile != "" && (lib.importJSON reportFile) ? system
            then
              reportFile
            else
              throw "hosts/${host.name}/facter.json: missing or empty; run install.sh for this host, or nixos-facter on it";
        }

        # hardware video decoding on Intel GPUs; facter enables graphics, not the VA-API driver
        (lib.mkIf (has "intel") {
          hardware.graphics.extraPackages = [
            pkgs.intel-media-driver
            pkgs.vpl-gpu-rt
          ];
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
          # the chosen profile (state.ini)
          axon.persist.directories = [ "/var/lib/power-profiles-daemon" ];
        })
      ];
    };
}
