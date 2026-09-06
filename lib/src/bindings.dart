import 'dart:typed_data';

import 'package:deepfilternet/src/shared.dart';

/// Fallback DeepFilterNet API for unsupported Dart platforms.
///
/// This class mirrors the native and Web implementations so that the package
/// can be imported on every platform. Creating or using a processor is not
/// supported on platforms without a native or Web implementation.
class DeepFilterNet {
  /// Creates a DeepFilterNet processor.
  factory DeepFilterNet.create({String? modelPath, double attenLimitDb = 100, DeepFilterNetLogLevel? logLevel}) =>
      throw _unsupported;

  /// Creates the unsupported-platform fallback.
  ///
  /// Platform implementations extend this class through this constructor.
  DeepFilterNet.unsupported();

  static Error get _unsupported => UnsupportedError('DeepFilterNet is not supported on this platform.');

  /// Prepares the platform implementation for processing.
  static Future<void> initialize() => Future<void>.error(_unsupported);

  /// Number of samples accepted by [process].
  int get frameLength => throw _unsupported;

  /// Processes one frame and returns the enhanced samples.
  Float32List process(Float32List frame) => throw _unsupported;

  /// Updates the maximum attenuation applied by the model.
  void setAttenuationLimit(double limitDb) => throw _unsupported;

  /// Enables the post-filter with [beta], or disables it with zero.
  void setPostFilterBeta(double beta) => throw _unsupported;

  /// Removes and returns the next native log message, if logging is enabled.
  String? nextLogMessage() => throw _unsupported;

  /// Releases the processor.
  void dispose() => throw _unsupported;
}
