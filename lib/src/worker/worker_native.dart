import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:deepfilternet/src/bindings_native.dart';
import 'package:deepfilternet/src/shared/common.dart';
import 'package:deepfilternet/src/worker/worker.dart' as stub;
import 'package:isolate_channel/isolate_channel.dart';

const _logChannelName = 'deepfilternet/logs';

enum _WorkerMethod {
  initialize,
  process,
  setAttenuationLimit,
  setPostFilterBeta,
  dispose;

  static _WorkerMethod? parse(String name) {
    for (final method in values) {
      if (method.name == name) return method;
    }

    return null;
  }
}

extension _CallUtils on IsolateMethodCall {
  _WorkerMethod? get methodKind => .parse(method);
}

/// A method channel that rejects work after its worker has been disposed.
final class _WorkerMethodChannel extends IsolateMethodChannel {
  new(IsolateConnection connection) : super('deepfilternet/worker', connection);

  bool _disposed = false;

  Future<T> invoke<T>(_WorkerMethod method, [dynamic arguments]) {
    return invokeMethod<T>(method.name, arguments);
  }

  @override
  Future<T> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (_disposed) {
      throw StateError('This DeepFilterNet worker has been disposed.');
    }

    return super.invokeMethod<T>(method, arguments);
  }

  /// Sends the disposal request while preventing all subsequent invocations.
  Future<void> disposeWorker() {
    _disposed = true;
    return super.invokeMethod<void>(_WorkerMethod.dispose.name);
  }
}

class const _DeepFilterNetParams({
  final String? modelPath,
  final double attenLimitDb = 100,
  final DeepFilterNetLogLevel? logLevel,
});

final class DeepFilterNetWorker extends stub.DeepFilterNetWorker {
  new _(this._connection, super.frameLength);

  final IsolateConnection _connection;
  late final _methods = _WorkerMethodChannel(_connection);

  late final StreamSubscription<String> _logSubscription = IsolateEventChannel(
    _logChannelName,
    _connection,
  ).receiveBroadcastStream().cast<String>().listen(_logs.add, onError: _logs.addError);

  final StreamController<String> _logs = .broadcast(sync: true);

  @override
  Stream<String> get logs => _logs.stream;

  static Future<DeepFilterNetWorker> spawn({
    String? modelPath,
    double attenLimitDb = 100,
    DeepFilterNetLogLevel? logLevel,
  }) async {
    final connection = await spawnIsolate(_BackendWorker.entryPoint);

    try {
      final methods = _WorkerMethodChannel(connection);
      final params = _DeepFilterNetParams(modelPath: modelPath, attenLimitDb: attenLimitDb, logLevel: logLevel);
      final frameLength = await methods.invoke<int>(.initialize, params);
      return ._(connection, frameLength);
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  @override
  Future<Float32List> process(Float32List frame) async {
    if (frame.length != frameLength) {
      throw ArgumentError.value(frame.length, 'frame.length', 'Expected exactly $frameLength samples.');
    }

    final result = await _methods.invoke<TransferableTypedData>(
      .process,
      TransferableTypedData.fromList([
        frame.buffer.asUint8List(frame.offsetInBytes, frame.lengthInBytes),
      ]),
    );

    return result.materialize().asFloat32List();
  }

  @override
  Future<void> setAttenuationLimit(double limitDb) => _methods.invoke(.setAttenuationLimit, limitDb);

  @override
  Future<void> setPostFilterBeta(double beta) => _methods.invoke(.setPostFilterBeta, beta);

  @override
  Future<void> dispose() => _dispose();

  late final _dispose = Once<void>(() async {
    try {
      await _methods.disposeWorker();
    } finally {
      await _logSubscription.cancel();
      await _logs.close();
      _connection.close();
    }
  });
}

final class _BackendWorker(final SendPort? send) {
  this {
    final connection = setupIsolate(send);

    // Create message handler
    _WorkerMethodChannel(connection).setMethodCallHandler(onMessage);

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
    return switch (call.methodKind) {
      .initialize => init(call),
      .process => process(call),
      .setAttenuationLimit => setAttenuationLimit(call.arguments),
      .setPostFilterBeta => setPostFilterBeta(call.arguments),
      .dispose => dispose(),
      null => call.notImplemented(),
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
