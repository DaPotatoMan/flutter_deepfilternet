import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:deepfilternet/src/bindings.dart' as stub;
import 'package:deepfilternet/src/bindings_native_generated.dart';
import 'package:deepfilternet/src/shared.dart';
import 'package:ffi/ffi.dart';

/// A stateful DeepFilterNet processor for 48 kHz mono float32 audio.
class DeepFilterNet extends stub.DeepFilterNet {
  DeepFilterNet._(this._bindings, this._state, this.frameLength) : super.unsupported();

  /// Creates a processor using the model embedded in the published binary.
  ///
  /// Pass [modelPath] to load a compatible ONNX model tarball instead.
  /// Set [logLevel] to collect native log messages with [nextLogMessage].
  factory DeepFilterNet.create({String? modelPath, double attenLimitDb = 100, DeepFilterNetLogLevel? logLevel}) {
    final bindings = DfBindings(_openLibrary());
    final path = (modelPath ?? '').toNativeUtf8();
    final nativeLogLevel = logLevel?.name.toNativeUtf8();
    try {
      final state = bindings.df_create(
        path.cast<Char>(),
        attenLimitDb,
        nativeLogLevel?.cast<Char>() ?? nullptr.cast<Char>(),
      );
      if (state == nullptr) {
        throw StateError('libdf failed to create a DeepFilterNet state.');
      }
      final frameLength = bindings.df_get_frame_length(state);
      return DeepFilterNet._(bindings, state, frameLength);
    } finally {
      malloc.free(path);
      if (nativeLogLevel != null) malloc.free(nativeLogLevel);
    }
  }
  final DfBindings _bindings;
  final Pointer<DFState> _state;
  bool _disposed = false;

  /// Prepares the package for processing.
  ///
  /// Native platforms are ready immediately. Calling this before [DeepFilterNet.create]
  /// keeps application code compatible with Web, where Wasm must be loaded.
  static Future<void> initialize() async {}

  @override
  final int frameLength;

  @override
  Float32List process(Float32List frame) {
    _ensureUsable();
    if (frame.length != frameLength) {
      throw ArgumentError.value(frame.length, 'frame.length', 'Expected exactly $frameLength samples.');
    }

    final input = calloc<Float>(frameLength);
    final output = calloc<Float>(frameLength);
    try {
      input.asTypedList(frameLength).setAll(0, frame);
      _bindings.df_process_frame(_state, input, output);
      return Float32List.fromList(output.asTypedList(frameLength));
    } finally {
      calloc
        ..free(input)
        ..free(output);
    }
  }

  @override
  void setAttenuationLimit(double limitDb) {
    _ensureUsable();
    _bindings.df_set_atten_lim(_state, limitDb);
  }

  @override
  void setPostFilterBeta(double beta) {
    _ensureUsable();
    _bindings.df_set_post_filter_beta(_state, beta);
  }

  @override
  String? nextLogMessage() {
    _ensureUsable();
    final message = _bindings.df_next_log_msg(_state);
    if (message == nullptr) return null;
    try {
      return message.cast<Utf8>().toDartString();
    } finally {
      _bindings.df_free_log_msg(message);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _bindings.df_free(_state);
    _disposed = true;
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('This DeepFilterNet instance has been disposed.');
    }
  }
}

DynamicLibrary _openLibrary() {
  if (Platform.isIOS) return DynamicLibrary.process();
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libdf.so');
  }
  if (Platform.isMacOS) return DynamicLibrary.open('libdf.dylib');
  if (Platform.isWindows) return DynamicLibrary.open('df.dll');
  throw UnsupportedError('DeepFilterNet is not available on ${Platform.operatingSystem}.');
}
