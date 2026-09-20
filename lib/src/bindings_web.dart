import 'dart:js_interop';
import 'dart:typed_data';

import 'package:deepfilternet/src/bindings.dart' as stub;
import 'package:deepfilternet/src/shared/common.dart';
import 'package:deepfilternet/src/shared/web_utils.dart';

class DeepFilterNet implements stub.DeepFilterNet {
  new _(this._state, this.frameLength);

  factory create({
    String? modelPath,
    double attenLimitDb = 100,
    DeepFilterNetLogLevel? logLevel,
  }) {
    if (modelPath != null) {
      throw UnsupportedError('modelPath is not supported on Web. Use the bundled model instead.');
    }

    if (!WasmBindgen.isLoaded) {
      throw StateError(
        'DeepFilterNet is not initialized. '
        'Call and await DeepFilterNet.initialize() before create().',
      );
    }

    final bindings = WasmBindgen.instance.value;
    final modelBytes = WasmBindgen.modelBytes.value;

    final state = bindings.create(modelBytes.toJS, attenLimitDb).toDartInt;
    final frameLength = bindings.frameLength(state).toDartInt;

    return ._(state, frameLength);
  }

  /// Loads the Wasm module required by [DeepFilterNet.create]. Safe to call repeatedly.
  static Future<void> initialize() => WasmBindgen.load();

  @override
  final int frameLength;
  final int _state;

  bool _disposed = false;

  WasmBindgen get bindings {
    if (_disposed) throw StateError('Cannot use a disposed DeepFilterNet instance.');
    return WasmBindgen.instance.value;
  }

  @override
  Stream<String> get logs => const .empty();

  @override
  Float32List process(Float32List frame) {
    if (frame.length != frameLength) {
      throw ArgumentError.value(frame.length, 'frame.length', 'Expected exactly $frameLength samples.');
    }

    final output = bindings.process(_state, frame.toJS);
    return Float32List.fromList(output.toDart);
  }

  @override
  void setAttenuationLimit(double limitDb) {
    bindings.setAttenuationLimit(_state, limitDb);
  }

  @override
  void setPostFilterBeta(double beta) {
    bindings.setPostFilterBeta(_state, beta);
  }

  @override
  void dispose() {
    if (_disposed) return;

    bindings.free(_state);
    _disposed = true;
  }
}

/// The ESM module namespace emitted by wasm-bindgen in `df.js`.
extension type WasmBindgen(JSObject _) implements JSObject {
  static final modelBytes = Required<Uint8List>(
    onThrow: () =>
        throw StateError('DeepFilterNet model is not loaded. Call and await DeepFilterNet.initialize() first.'),
  );

  static final instance = Required<WasmBindgen>(
    onThrow: () => throw StateError(
      'DeepFilterNet Wasm module is not loaded. '
      'Call and await DeepFilterNet.initialize() first.',
    ),
  );

  static final load = Once<void>(() async {
    instance.set(
      .new(await WebAsset.import('df.js')),
    );

    final wasmPath = WebAsset.resolvePath('df_bg.wasm').toJS;
    final (model, _) = await (
      WebAsset.load('DeepFilterNet3_onnx.tar.gz'),
      instance.value.initialize(wasmPath).toDart,
    ).wait;

    modelBytes.set(model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes));
  });

  static bool get isLoaded => modelBytes.isSet && instance.isSet;

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
