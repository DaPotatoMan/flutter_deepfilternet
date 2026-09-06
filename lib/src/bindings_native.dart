import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:deepfilternet/src/bindings.dart' as stub;
import 'package:deepfilternet/src/bindings_native_generated.dart';
import 'package:deepfilternet/src/shared.dart';
import 'package:ffi/ffi.dart';

class DeepFilterNet implements stub.DeepFilterNet {
  new _(this._state, this.frameLength);

  factory create({String? modelPath, double attenLimitDb = 100, DeepFilterNetLogLevel? logLevel}) {
    final path = (modelPath ?? '').toNativeUtf8();
    final nativeLogLevel = logLevel?.name.toNativeUtf8();

    try {
      final state = df_create(
        path.cast<Char>(),
        attenLimitDb,
        nativeLogLevel?.cast<Char>() ?? nullptr.cast<Char>(),
      );

      if (state == nullptr) {
        throw StateError('libdf failed to create a DeepFilterNet state.');
      }

      final frameLength = df_get_frame_length(state);
      return ._(state, frameLength);
    } finally {
      malloc.free(path);
      if (nativeLogLevel != null) malloc.free(nativeLogLevel);
    }
  }

  final Pointer<DFState> _state;
  final _logs = StreamController<String>.broadcast(sync: true);

  bool _disposed = false;

  static Future<void> initialize() async {}

  @override
  final int frameLength;

  @override
  Stream<String> get logs => _logs.stream;

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
      df_process_frame(_state, input, output);

      return .fromList(output.asTypedList(frameLength));
    } finally {
      calloc
        ..free(input)
        ..free(output);

      _drainLogs();
    }
  }

  @override
  void setAttenuationLimit(double limitDb) {
    _ensureUsable();
    df_set_atten_lim(_state, limitDb);
    _drainLogs();
  }

  @override
  void setPostFilterBeta(double beta) {
    _ensureUsable();
    df_set_post_filter_beta(_state, beta);
    _drainLogs();
  }

  @override
  void dispose() {
    if (_disposed) return;

    _drainLogs();
    df_free(_state);
    _disposed = true;
    unawaited(_logs.close());
  }

  void _drainLogs() {
    while (true) {
      final message = df_next_log_msg(_state);
      if (message == nullptr) return;
      try {
        _logs.add(message.cast<Utf8>().toDartString());
      } finally {
        df_free_log_msg(message);
      }
    }
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('This DeepFilterNet instance has been disposed.');
  }
}
