import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:deepfilternet/src/bindings.dart' as stub;
import 'package:deepfilternet/src/shared.dart';
import 'package:flutter/services.dart';

const _assetBase = 'packages/deepfilternet/assets/web';

String _resolveAsset(String filename) {
  final path = ui_web.assetManager.getAssetUrl('$_assetBase/$filename');
  return Uri.base.resolve(path).toString();
}

class DeepFilterNet implements stub.DeepFilterNet {
  new _(this._state, this.frameLength);

  factory create({
    String? modelPath,
    double attenLimitDb = 100,
    DeepFilterNetLogLevel? logLevel,
  }) {
    if (modelPath != null) {
      throw UnsupportedError('Web does not support modelPath.');
    }

    final modelBytes = _modelBytes;
    final wasmBindgen = _wasmBindgen;

    if (modelBytes == null || wasmBindgen == null) {
      throw StateError('Call and await DeepFilterNet.initialize() before create().');
    }

    final state = wasmBindgen.create(modelBytes.toJS, attenLimitDb).toDartInt;
    final frameLength = wasmBindgen.frameLength(state).toDartInt;

    return ._(state, frameLength);
  }

  static Future<void>? _initializing;
  static Uint8List? _modelBytes;
  static _WasmBindgen? _wasmBindgen;

  final int _state;

  @override
  final int frameLength;

  bool _disposed = false;

  @override
  Stream<String> get logs => const Stream<String>.empty();

  /// Loads the Wasm module required by [DeepFilterNet.create]. Safe to call repeatedly.
  static Future<void> initialize() {
    return _initializing ??= _initialize();
  }

  static Future<void> _initialize() async {
    final wasmBindgen = _wasmBindgen ??= _WasmBindgen(await importModule(_resolveAsset('df.js').toJS).toDart);
    await wasmBindgen.initialize(_resolveAsset('df_bg.wasm').toJS).toDart;

    final model = await rootBundle.load('$_assetBase/DeepFilterNet3_onnx.tar.gz');
    _modelBytes = model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes);
  }

  @override
  Float32List process(Float32List frame) {
    _ensureUsable();
    if (frame.length != frameLength) {
      throw ArgumentError.value(frame.length, 'frame.length', 'Expected exactly $frameLength samples.');
    }
    final output = _wasmBindgen!.process(_state, frame.toJS);
    return Float32List.fromList(output.toDart);
  }

  @override
  void setAttenuationLimit(double limitDb) {
    _ensureUsable();
    _wasmBindgen!.setAttenuationLimit(_state, limitDb);
  }

  @override
  void setPostFilterBeta(double beta) {
    _ensureUsable();
    _wasmBindgen!.setPostFilterBeta(_state, beta);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _wasmBindgen!.free(_state);
    _disposed = true;
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('This DeepFilterNet instance has been disposed.');
    }
  }
}

/// The ESM module namespace emitted by wasm-bindgen in `df.js`.
extension type _WasmBindgen(JSObject _) implements JSObject {
  @JS('default')
  external JSPromise<JSAny?> initialize(JSString wasmUrl);

  @JS('df_create')
  external JSNumber create(JSUint8Array modelBytes, double attenuationLimitDb);

  @JS('df_get_frame_length')
  external JSNumber frameLength(int state);

  @JS('df_process_frame')
  external JSFloat32Array process(int state, JSFloat32Array input);

  @JS('df_set_atten_lim')
  external void setAttenuationLimit(int state, double limitDb);

  @JS('df_set_post_filter_beta')
  external void setPostFilterBeta(int state, double beta);

  @JS('df_free')
  external void free(int state);
}
