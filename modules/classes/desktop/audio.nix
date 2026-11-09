# Sound through PipeWire, which also serves ALSA and PulseAudio apps.
{
  flake.modules.nixos.desktop = {
    # the desktop session turns PipeWire on with ALSA and PulseAudio; its realtime scheduling
    # needs rtkit, which nothing enables
    security.rtkit.enable = true;
  };
}
