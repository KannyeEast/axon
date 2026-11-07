# Sound through PipeWire, which also serves ALSA and PulseAudio apps.
{
  flake.modules.nixos.desktop = {
    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };
  };
}
