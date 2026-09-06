//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <audio_decoder/audio_decoder_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) audio_decoder_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AudioDecoderPlugin");
  audio_decoder_plugin_register_with_registrar(audio_decoder_registrar);
}
