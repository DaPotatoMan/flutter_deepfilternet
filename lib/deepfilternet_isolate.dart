import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:deepfilternet/deepfilternet.dart';

/// A [DeepFilterNet] processor that runs on a dedicated worker isolate.
///
/// Create one instance per audio stream. Calls to [process] are handled in
/// order, preserving the state required by DeepFilterNet between frames.
class DeepFilterNetIsolate {
  DeepFilterNetIsolate._(
    this._commands,
    this._errors,
    this._exits,
    this.frameLength,
  ) {
    _errors.listen((Object? message) {
      if (!_disposing) _reportFailure('Worker isolate failed: $message');
    });
    _exits.listen((Object? _) {
      if (!_disposing) _reportFailure('Worker isolate exited unexpectedly.');
    });
  }

  final SendPort _commands;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final Completer<String> _failure = Completer<String>();

  /// Number of samples required by each input frame.
  final int frameLength;

  bool _disposing = false;
  bool _disposed = false;

  /// Starts a worker isolate and creates its native DeepFilterNet state.
  static Future<DeepFilterNetIsolate> spawn({
    String? modelPath,
    double attenLimitDb = 100,
    DeepFilterNetLogLevel? logLevel,
  }) async {
    final ready = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    try {
      await Isolate.spawn<List<Object?>>(
        _dfNetWorker,
        <Object?>[ready.sendPort, modelPath, attenLimitDb, logLevel?.index],
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );

      final message = await ready.first;
      if (message is! List<Object?> || message.isEmpty) {
        throw StateError('DeepFilterNet worker failed to start: $message');
      }
      if (message.first == _ready) {
        return DeepFilterNetIsolate._(
          message[1]! as SendPort,
          errors,
          exits,
          message[2]! as int,
        );
      }
      throw StateError('DeepFilterNet worker failed to start: ${message[1]}');
    } catch (_) {
      errors.close();
      exits.close();
      rethrow;
    } finally {
      ready.close();
    }
  }

  /// Processes one 48 kHz mono frame on the worker isolate.
  ///
  /// The input must contain exactly [frameLength] samples. The list's backing
  /// bytes are transferred to the worker, so do not use [frame] afterwards.
  Future<Float32List> process(Float32List frame) async {
    _ensureUsable();
    final reply = ReceivePort();
    try {
      final bytes = frame.buffer.asUint8List(
        frame.offsetInBytes,
        frame.lengthInBytes,
      );
      _commands.send(<Object?>[
        _process,
        TransferableTypedData.fromList(<TypedData>[bytes]),
        reply.sendPort,
      ]);
      final message = await _awaitReply(reply.first);
      return _readResult(message);
    } finally {
      reply.close();
    }
  }

  /// Updates the maximum attenuation applied by the model.
  Future<void> setAttenuationLimit(double limitDb) {
    return _sendVoidCommand(_setAttenuationLimit, limitDb);
  }

  /// Enables the post-filter with [beta], or disables it with zero.
  Future<void> setPostFilterBeta(double beta) {
    return _sendVoidCommand(_setPostFilterBeta, beta);
  }

  /// Removes and returns the next native log message, if logging is enabled.
  ///
  /// Returns `null` when no message is currently available.
  Future<String?> nextLogMessage() async {
    _ensureUsable();
    final reply = ReceivePort();
    try {
      _commands.send(<Object?>[_nextLogMessage, reply.sendPort]);
      final message = await _awaitReply(reply.first);
      if (message is List<Object?> && message.first == _result) {
        return message[1] as String?;
      }
      _readVoidResult(message);
      throw StateError('DeepFilterNet worker returned an invalid response.');
    } finally {
      reply.close();
    }
  }

  /// Disposes the native processor and stops the worker isolate.
  Future<void> dispose() async {
    if (_disposed || _disposing) return;
    _disposing = true;
    final reply = ReceivePort();
    try {
      _commands.send(<Object?>[_dispose, reply.sendPort]);
      _readVoidResult(await reply.first);
    } finally {
      _disposed = true;
      reply.close();
      _errors.close();
      _exits.close();
    }
  }

  Future<void> _sendVoidCommand(String command, double value) async {
    _ensureUsable();
    final reply = ReceivePort();
    try {
      _commands.send(<Object?>[command, value, reply.sendPort]);
      _readVoidResult(await _awaitReply(reply.first));
    } finally {
      reply.close();
    }
  }

  Future<Object?> _awaitReply(Future<Object?> reply) {
    return Future.any<Object?>(<Future<Object?>>[
      reply,
      _failure.future.then<Object?>(
        (String reason) => throw StateError(reason),
      ),
    ]);
  }

  Float32List _readResult(Object? message) {
    if (message is List<Object?> && message.first == _result) {
      final data = message[1]! as TransferableTypedData;
      return data.materialize().asFloat32List();
    }
    _readVoidResult(message);
    throw StateError('DeepFilterNet worker returned an invalid response.');
  }

  void _readVoidResult(Object? message) {
    if (message is List<Object?> && message.first == _error) {
      throw StateError('${message[1]}\n${message[2]}');
    }
    if (message is! List<Object?> || message.first != _result) {
      throw StateError('DeepFilterNet worker returned an invalid response.');
    }
  }

  void _ensureUsable() {
    if (_disposed || _disposing) {
      throw StateError('This DeepFilterNet isolate has been disposed.');
    }
  }

  void _reportFailure(String reason) {
    if (!_failure.isCompleted) _failure.complete(reason);
  }
}

const _ready = 'ready';
const _process = 'process';
const _setAttenuationLimit = 'setAttenuationLimit';
const _setPostFilterBeta = 'setPostFilterBeta';
const _nextLogMessage = 'nextLogMessage';
const _dispose = 'dispose';
const _result = 'result';
const _error = 'error';

@pragma('vm:entry-point')
void _dfNetWorker(List<Object?> configuration) {
  final readyPort = configuration[0]! as SendPort;
  try {
    final logLevelIndex = configuration[3] as int?;
    final filter = DeepFilterNet.create(
      modelPath: configuration[1] as String?,
      attenLimitDb: configuration[2]! as double,
      logLevel: logLevelIndex == null ? null : DeepFilterNetLogLevel.values[logLevelIndex],
    );
    final commands = ReceivePort();
    readyPort.send(<Object?>[_ready, commands.sendPort, filter.frameLength]);

    commands.listen((Object? message) {
      final command = message! as List<Object?>;
      final replyPort = command.last! as SendPort;
      try {
        switch (command.first) {
          case _process:
            final data = command[1]! as TransferableTypedData;
            final frame = data.materialize().asFloat32List();
            final output = filter.process(frame);
            replyPort.send(<Object?>[
              _result,
              TransferableTypedData.fromList(<TypedData>[
                output.buffer.asUint8List(
                  output.offsetInBytes,
                  output.lengthInBytes,
                ),
              ]),
            ]);
          case _dispose:
            filter.dispose();
            replyPort.send(<Object?>[_result]);
            commands.close();
          case _setAttenuationLimit:
            filter.setAttenuationLimit(command[1]! as double);
            replyPort.send(<Object?>[_result]);
          case _setPostFilterBeta:
            filter.setPostFilterBeta(command[1]! as double);
            replyPort.send(<Object?>[_result]);
          case _nextLogMessage:
            replyPort.send(<Object?>[_result, filter.nextLogMessage()]);
          default:
            throw ArgumentError('Unknown DeepFilterNet worker command.');
        }
      } catch (error, stackTrace) {
        replyPort.send(<Object?>[
          _error,
          error.toString(),
          stackTrace.toString(),
        ]);
      }
    });
  } catch (error, stackTrace) {
    readyPort.send(<Object?>[_error, error.toString(), stackTrace.toString()]);
  }
}
