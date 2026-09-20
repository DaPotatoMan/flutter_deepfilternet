import 'dart:async';
import 'dart:typed_data';

import 'package:deepfilternet/src/shared/common.dart';

/// A DeepFilterNet processor that runs on a dedicated worker.
///
/// Create one instance per audio stream. Calls to [process] are handled in
/// order, preserving the state required by DeepFilterNet between frames.
abstract class DeepFilterNetWorker {
  new(this.frameLength);

  static Error get _unsupported => UnsupportedError('DeepFilterNet is not supported on this platform.');

  /// Starts a worker and creates its DeepFilterNet state.
  ///
  /// [modelPath] is supported only on native platforms. Web always loads the
  /// bundled model.
  static Future<DeepFilterNetWorker> spawn({
    String? modelPath,
    double attenLimitDb = 100,
    DeepFilterNetLogLevel? logLevel,
  }) => Future.error(_unsupported);

  /// Number of samples required by each input frame.
  final int frameLength;

  /// Diagnostic messages emitted by the worker processor.
  Stream<String> get logs;

  /// Processes one 48 kHz mono frame on the worker.
  ///
  /// The input must contain exactly [frameLength] samples.
  Future<Float32List> process(Float32List frame) => throw _unsupported;

  /// Updates the maximum attenuation applied by the model.
  Future<void> setAttenuationLimit(double limitDb) => throw _unsupported;

  /// Enables the post-filter with [beta], or disables it with zero.
  Future<void> setPostFilterBeta(double beta) => throw _unsupported;

  /// Disposes the processor and stops the worker.
  Future<void> dispose() => throw _unsupported;
}
