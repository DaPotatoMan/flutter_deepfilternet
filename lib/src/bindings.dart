import 'dart:async';
import 'dart:typed_data';

import 'package:deepfilternet/src/shared/common.dart';

/// A stateful DeepFilterNet processor for 48 kHz mono float32 audio.
class DeepFilterNet {
  /// Creates a processor using the model embedded in the published binary.
  ///
  /// Call and await [initialize] first. Web does not support [modelPath].
  ///
  /// Set [modelPath] to load a compatible ONNX model tarball instead.
  ///
  /// Set [logLevel] to collect native diagnostic messages through [logs].
  factory create({
    String? modelPath,
    double attenLimitDb = 100,
    DeepFilterNetLogLevel? logLevel,
  }) => throw _unsupported;

  /// Creates the unsupported-platform fallback.
  ///
  /// Platform implementations extend this class through this constructor.
  DeepFilterNet.unsupported();

  static Error get _unsupported => UnsupportedError('DeepFilterNet is not supported on this platform.');

  /// Prepares the package for processing.
  ///
  /// Native platforms are ready immediately. Calling this before [DeepFilterNet.create]
  /// keeps application code compatible with Web, where Wasm must be loaded.
  static Future<void> initialize() => Future<void>.error(_unsupported);

  /// Number of samples accepted by [process].
  int get frameLength => throw _unsupported;

  /// Processes one frame and returns the enhanced samples.
  Float32List process(Float32List frame) => throw _unsupported;

  /// Updates the maximum attenuation applied by the model.
  void setAttenuationLimit(double limitDb) => throw _unsupported;

  /// Enables the post-filter with [beta], or disables it with zero.
  void setPostFilterBeta(double beta) => throw _unsupported;

  /// Native diagnostic messages emitted while using this processor.
  ///
  /// The stream is empty when logging is unavailable or not enabled.
  Stream<String> get logs => throw _unsupported;

  /// Releases the processor.
  void dispose() => throw _unsupported;
}
