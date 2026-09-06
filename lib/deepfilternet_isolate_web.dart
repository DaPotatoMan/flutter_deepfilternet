import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:deepfilternet/deepfilternet.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

const _assetBase = 'packages/deepfilternet/assets/web';

enum _EventType { initialize, process, setAttenuationLimit, setPostFilterBeta, dispose }

String _assetUrl(String file) => Uri.base.resolve(ui_web.assetManager.getAssetUrl('$_assetBase/$file')).toString();

/// A DeepFilterNet processor that runs in a Web Worker.
class DeepFilterNetIsolate {
  DeepFilterNetIsolate._(this._worker, this._state, this.frameLength) {
    _worker.onmessage = ((web.Event event) {
      final response = _WorkerResponse.fromMessage(event);
      final reply = _replies.remove(response.id);
      if (reply == null) return;
      if (response.type == 'error') {
        reply.completeError(StateError('${response.message}\n${response.stack ?? ''}'));
      } else {
        reply.complete(response);
      }
    }).toJS;
    _worker.onerror = ((web.Event event) {
      _fail(StateError('DeepFilterNet worker failed: $event'));
    }).toJS;
  }

  final web.Worker _worker;
  final int _state;
  final Map<int, Completer<_WorkerResponse>> _replies = {};
  int _nextId = 0;
  bool _disposed = false;

  /// Number of samples required by each input frame.
  final int frameLength;

  /// Starts a Web Worker and creates its DeepFilterNet state.
  static Future<DeepFilterNetIsolate> spawn({
    String? modelPath,
    double attenLimitDb = 100,
    DeepFilterNetLogLevel? logLevel,
  }) async {
    if (modelPath != null) {
      throw UnsupportedError('Web does not support modelPath.');
    }

    final worker = web.Worker(_assetUrl('df_worker.js').toJS, web.WorkerOptions(type: 'module'));
    final bridge = DeepFilterNetIsolate._(worker, 0, 0);
    try {
      final asset = await rootBundle.load('$_assetBase/DeepFilterNet3_onnx.tar.gz');
      final model = Uint8List.fromList(asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes));
      final buffer = model.buffer.toJS;
      final response = await bridge._send(
        modelBytes: JSUint8Array(buffer, 0, model.length),
        attenLimitDb: attenLimitDb,
        transfer: _transfer(buffer),
      );
      return DeepFilterNetIsolate._(worker, response.state!, response.frameLength!);
    } catch (_) {
      worker.terminate();
      rethrow;
    }
  }

  /// Processes one 48 kHz mono frame on the worker.
  Future<Float32List> process(Float32List frame) async {
    _ensureUsable();
    if (frame.length != frameLength) {
      throw ArgumentError.value(frame.length, 'frame.length', 'Expected exactly $frameLength samples.');
    }
    final buffer = frame.buffer.toJS;
    final response = await _send(
      type: _EventType.process,
      frame: JSFloat32Array(buffer, frame.offsetInBytes, frame.length),
      transfer: _transfer(buffer),
    );
    return Float32List.fromList(response.frame!.toDart);
  }

  /// Updates the maximum attenuation applied by the model.
  Future<void> setAttenuationLimit(double limitDb) async {
    _ensureUsable();
    await _send(type: _EventType.setAttenuationLimit, limitDb: limitDb);
  }

  /// Enables the post-filter with [beta], or disables it with zero.
  Future<void> setPostFilterBeta(double beta) async {
    _ensureUsable();
    await _send(type: _EventType.setPostFilterBeta, beta: beta);
  }

  /// Web workers do not expose native log messages.
  Future<String?> nextLogMessage() async {
    _ensureUsable();
    return null;
  }

  /// Releases the Wasm state and terminates its worker.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _send(type: _EventType.dispose);
    } finally {
      _worker.terminate();
      _fail(StateError('DeepFilterNet worker has been disposed.'));
    }
  }

  Future<_WorkerResponse> _send({
    _EventType type = _EventType.initialize,
    JSUint8Array? modelBytes,
    double? attenLimitDb,
    JSFloat32Array? frame,
    double? limitDb,
    double? beta,
    JSArray<JSAny?>? transfer,
  }) {
    final id = _nextId++;
    final reply = Completer<_WorkerResponse>();
    _replies[id] = reply;
    final message = _WorkerRequest(
      id: id,
      type: type.name,
      state: _state,
      modelBytes: modelBytes,
      attenLimitDb: attenLimitDb,
      frame: frame,
      limitDb: limitDb,
      beta: beta,
    );
    if (transfer == null) {
      _worker.postMessage(message);
    } else {
      _worker.postMessage(message, transfer);
    }
    return reply.future;
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('This DeepFilterNet isolate has been disposed.');
    }
  }

  void _fail(Object error) {
    for (final reply in _replies.values) {
      if (!reply.isCompleted) reply.completeError(error);
    }
    _replies.clear();
  }
}

JSArray<JSAny?> _transfer(JSObject value) => .new()..add(value);

@JS()
@anonymous
extension type _WorkerRequest._(JSObject _) implements JSObject {
  external factory _WorkerRequest({
    required int id,
    required String type,
    int? state,
    JSUint8Array? modelBytes,
    double? attenLimitDb,
    JSFloat32Array? frame,
    double? limitDb,
    double? beta,
  });
}

extension type _WorkerResponse(JSObject _) implements JSObject {
  factory fromMessage(web.Event event) {
    if (!event.isA<web.MessageEvent>()) throw StateError('Invalid type provided to create _WorkerResponse');

    event as web.MessageEvent;
    return .new(event.data! as JSObject);
  }

  external int get id;
  external String get type;
  external int? get state;
  external int? get frameLength;
  external JSFloat32Array? get frame;
  external String? get message;
  external String? get stack;
}
