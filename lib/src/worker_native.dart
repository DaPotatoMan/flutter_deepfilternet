import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:deepfilternet/src/bindings_native.dart';
import 'package:deepfilternet/src/shared.dart';
import 'package:deepfilternet/src/worker.dart' as stub;
import 'package:isolate_channel/isolate_channel.dart';

const _methodChannelName = 'deepfilternet/worker';
const _logChannelName = 'deepfilternet/logs';

abstract final class _WorkerMethod {
  static const initialize = 'initialize';
  static const process = 'process';
  static const setAttenuationLimit = 'setAttenuationLimit';
  static const setPostFilterBeta = 'setPostFilterBeta';
  static const dispose = 'dispose';
}

class const _DeepFilterNetParams({
  final String? modelPath,
  final double attenLimitDb = 100,
  final DeepFilterNetLogLevel? logLevel,
});

final class DeepFilterNetWorker extends stub.DeepFilterNetWorker {
  new _(IsolateConnection connection, super.frameLength) : _connection = connection;

  final IsolateConnection _connection;
  late final _methods = IsolateMethodChannel(_methodChannelName, _connection);

  late final StreamSubscription<String> _logSubscription = IsolateEventChannel(
    _logChannelName,
    _connection,
  ).receiveBroadcastStream().cast<String>().listen(_logs.add, onError: _logs.addError);

  final StreamController<String> _logs = .broadcast(sync: true);

  @override
  Stream<String> get logs => _logs.stream;

  Future<void>? _disposeFuture;

  static Future<DeepFilterNetWorker> spawn({
    String? modelPath,
    double attenLimitDb = 100,
    DeepFilterNetLogLevel? logLevel,
  }) async {
    final connection = await spawnIsolate(_BackendWorker.entryPoint);

    try {
      final methods = IsolateMethodChannel(_methodChannelName, connection);
      final params = _DeepFilterNetParams(modelPath: modelPath, attenLimitDb: attenLimitDb, logLevel: logLevel);
      final frameLength = await methods.invokeMethod<int>(_WorkerMethod.initialize, params);
      return ._(connection, frameLength);
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  @override
  Future<Float32List> process(Float32List frame) async {
    _ensureUsable();

    if (frame.length != frameLength) {
      throw ArgumentError.value(frame.length, 'frame.length', 'Expected exactly $frameLength samples.');
    }

    final result = await _methods.invokeMethod<TransferableTypedData>(
      _WorkerMethod.process,
      TransferableTypedData.fromList([
        frame.buffer.asUint8List(frame.offsetInBytes, frame.lengthInBytes),
      ]),
    );

    return result.materialize().asFloat32List();
  }

  @override
  Future<void> setAttenuationLimit(double limitDb) => _invokeVoid(_WorkerMethod.setAttenuationLimit, limitDb);

  @override
  Future<void> setPostFilterBeta(double beta) => _invokeVoid(_WorkerMethod.setPostFilterBeta, beta);

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    try {
      await _methods.invokeMethod<void>(_WorkerMethod.dispose);
    } finally {
      await _logSubscription.cancel();
      await _logs.close();
      _connection.close();
    }
  }

  Future<void> _invokeVoid(String method, double value) async {
    _ensureUsable();
    await _methods.invokeMethod<void>(method, value);
  }

  void _ensureUsable() {
    if (_disposeFuture != null) {
      throw StateError('This DeepFilterNet worker has been disposed.');
    }
  }
}

final class _BackendWorker(final SendPort? send) {
  this {
    final connection = setupIsolate(send);

    // Create message handler
    IsolateMethodChannel(_methodChannelName, connection).setMethodCallHandler(onMessage);

    // Create logging handler
    IsolateEventChannel(_logChannelName, connection).setStreamHandler(
      .inline(
        onListen: (_, sink) => logSink = sink,
        onCancel: (_) => logSink = null,
      ),
    );
  }

  @pragma('vm:entry-point')
  static void entryPoint(SendPort? send) => _BackendWorker(send);

  DeepFilterNet? filter;
  IsolateEventSink? logSink;
  StreamSubscription<String>? logSubscription;

  DeepFilterNet _filter() {
    if (filter case final df?) return df;

    throw StateError(
      'DeepFilterNet worker is not initialized. '
      'Call DeepFilterNetWorker.spawn first.',
    );
  }

  dynamic onMessage(IsolateMethodCall call) {
    return switch (call.method) {
      _WorkerMethod.initialize => init(call),
      _WorkerMethod.process => process(call),
      _WorkerMethod.setAttenuationLimit => setAttenuationLimit(call.arguments),
      _WorkerMethod.setPostFilterBeta => setPostFilterBeta(call.arguments),
      _WorkerMethod.dispose => dispose(),
      _ => call.notImplemented(),
    };
  }

  int init(IsolateMethodCall call) {
    if (filter != null) throw StateError('DeepFilterNet worker has already been initialized.');

    if (call.arguments case final _DeepFilterNetParams params?) {
      final filter = DeepFilterNet.create(
        modelPath: params.modelPath,
        attenLimitDb: params.attenLimitDb,
        logLevel: params.logLevel,
      );

      logSubscription = filter.logs.listen((message) => logSink?.success(message));
      this.filter = filter;

      return filter.frameLength;
    }

    throw StateError(
      'Invalid initialize arguments: expected _DeepFilterNetParams, got ${call.arguments.runtimeType}.',
    );
  }

  TransferableTypedData process(IsolateMethodCall call) {
    if (call.arguments case final TransferableTypedData data) {
      final frame = data.materialize().asFloat32List();
      final output = _filter().process(frame);

      return .fromList([
        output.buffer.asUint8List(output.offsetInBytes, output.lengthInBytes),
      ]);
    }

    throw StateError('Invalid process arguments: expected TransferableTypedData, got ${call.arguments.runtimeType}.');
  }

  void setAttenuationLimit(Object? value) {
    if (value case final double limitDb) return _filter().setAttenuationLimit(limitDb);
    throw StateError('Invalid attenuation limit: expected double, got ${value.runtimeType}.');
  }

  void setPostFilterBeta(Object? value) {
    if (value case final double beta) return _filter().setPostFilterBeta(beta);
    throw StateError('Invalid post-filter beta: expected double, got ${value.runtimeType}.');
  }

  void dispose() {
    _filter().dispose();
    unawaited(logSubscription?.cancel());

    filter = null;
    logSubscription = null;
  }
}
