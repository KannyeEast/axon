# Sound through PipeWire, which the desktop session turns on with ALSA and PulseAudio.
{
  flake.modules.nixos.desktop = {
    # PipeWire's realtime scheduling needs rtkit, which nothing else enables
    security.rtkit.enable = true;
  };
}
