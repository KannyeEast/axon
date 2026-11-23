# What nixpkgs' facter module leaves open from hosts/<name>/facter.json, and axon.laptop and
# axon.nvidia derived from the report.
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
      inherit (config.axon) host laptop nvidia;
      reportFile = host.dir + "/facter.json";
      report = config.hardware.facter.report;

      cards = report.hardware.graphics_card or [ ];
      cardsOf = vendor: lib.filter (card: (card.vendor.value or 0) == vendors.${vendor}) cards;
      has = vendor: cardsOf vendor != [ ];
      busId = vendor: pciBusId (lib.head (cardsOf vendor)).sysfs_bus_id;

      hybrid = nvidia && (has "intel" || has "amd");
    in
    {
      # ── contract ────────
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

      config = {
        # ── settings ────────
        # a throw: without a usable report, nixpkgs.hostPlatform fails before assertions run
        hardware.facter.reportPath =
          if
            lib.pathExists reportFile && lib.readFile reportFile != "" && (lib.importJSON reportFile) ? system
          then
            reportFile
          else
            throw "hosts/${host.name}/facter.json: missing or empty; run install.sh for this host, or nixos-facter on it";

        # hardware video decoding on Intel GPUs; facter enables graphics, not the VA-API driver
        hardware.graphics.extraPackages = lib.mkIf (has "intel") [
          pkgs.intel-media-driver
          pkgs.vpl-gpu-rt
        ];

        services.xserver.videoDrivers = lib.mkIf nvidia [ "nvidia" ];
        hardware.nvidia.open = lib.mkIf nvidia true;

        hardware.nvidia.prime = lib.mkIf hybrid (
          {
            offload.enable = true;
            offload.enableOffloadCmd = true;
            nvidiaBusId = busId "nvidia";
          }
          // lib.optionalAttrs (has "intel") { intelBusId = busId "intel"; }
          // lib.optionalAttrs (has "amd") { amdgpuBusId = busId "amd"; }
        );

        services.power-profiles-daemon.enable = lib.mkIf laptop true;

        # ── data ────────
        # the chosen profile (state.ini)
        axon.persist.directories = lib.mkIf laptop [ "/var/lib/power-profiles-daemon" ];
      };
    };
}
