import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:deepfilternet/deepfilternet.dart';

const _noisySamplePath = 'example/assets/noisy_sample.wav';
const _speechSamplePath = 'example/assets/noisy_speech_sample.wav';
const _pacedFrameCount = 1000;

/// Measures one awaited worker round trip using consecutive frames from the
/// real noisy sample. Worker creation and WAV decoding are outside timing.
final class WorkerFrameLatencyBenchmark extends AsyncBenchmarkBase {
  WorkerFrameLatencyBenchmark() : super('DeepFilterNetWorker.frameLatency');

  late final DeepFilterNetWorker _worker;
  late final List<Float32List> _frames;
  var _frameIndex = 0;
  double _resultSample = 0;

  @override
  Future<void> setup() async {
    _worker = await DeepFilterNetWorker.spawn();
    final input = _loadWav(_noisySamplePath);
    _frames = _completeFrames(input.samples, _worker.frameLength);
  }

  @override
  Future<void> run() async {
    final output = await _worker.process(_frames[_frameIndex]);
    _frameIndex = (_frameIndex + 1) % _frames.length;
    _resultSample = output[0];
  }

  @override
  Future<void> teardown() => _worker.dispose();
}

/// Measures complete enhancement of the speech sample and PCM16 WAV encoding
/// in memory. Input decoding and worker/model creation are outside timing.
final class WorkerFullEncodeBenchmark extends AsyncBenchmarkBase {
  WorkerFullEncodeBenchmark() : super('DeepFilterNetWorker.fullEncode', emitter: const _SecondsEmitter());

  late final DeepFilterNetWorker _worker;
  late final _PcmWav _input;
  int _encodedLength = 0;

  @override
  Future<void> setup() async {
    _worker = await DeepFilterNetWorker.spawn();
    _input = _loadWav(_speechSamplePath);
  }

  @override
  Future<void> run() async {
    final enhanced = Float32List(_input.samples.length);
    final frame = Float32List(_worker.frameLength);
    for (var offset = 0; offset < _input.samples.length; offset += frame.length) {
      final validLength = (_input.samples.length - offset).clamp(0, frame.length);
      frame.fillRange(0, frame.length, 0);
      frame.setRange(0, validLength, _input.samples, offset);
      final output = await _worker.process(frame);
      enhanced.setRange(offset, offset + validLength, output);
    }
    _encodedLength = _encodeMonoPcm16Wav(enhanced, sampleRate: _input.sampleRate).length;
  }

  @override
  Future<void> teardown() => _worker.dispose();
}

Future<void> _runBenchmarks() async {
  await WorkerFrameLatencyBenchmark().report();
  await WorkerFullEncodeBenchmark().report();

  final metrics = await _measurePacedLatency();
  print(
    'DeepFilterNetWorker.paced: '
    'p95=${metrics.p95Micros} us, '
    'p99=${metrics.p99Micros} us, '
    'peakQueueDepth=${metrics.peakQueueDepth}',
  );
}

Future<_PacedMetrics> _measurePacedLatency() async {
  final worker = await DeepFilterNetWorker.spawn();
  try {
    final input = _loadWav(_noisySamplePath);
    final frames = _completeFrames(input.samples, worker.frameLength);
    final period = Duration(
      microseconds: (worker.frameLength * Duration.microsecondsPerSecond / input.sampleRate).round(),
    );
    final latencies = <int>[];
    final pending = <Future<void>>[];
    final completed = Completer<void>();
    var frameIndex = 0;
    var peakQueueDepth = 0;
    double resultSample = 0;

    late final Timer timer;
    timer = Timer.periodic(period, (_) {
      if (frameIndex == _pacedFrameCount) {
        timer.cancel();
        Future.wait(pending).then(completed.complete, onError: completed.completeError);
        return;
      }

      final stopwatch = Stopwatch()..start();
      late final Future<void> call;
      call = worker.process(frames[frameIndex++ % frames.length]).then((output) {
        resultSample = output[0];
        latencies.add(stopwatch.elapsedMicroseconds);
      });
      pending.add(call);
      peakQueueDepth = peakQueueDepth < pending.length - 1 ? pending.length - 1 : peakQueueDepth;
      unawaited(call.whenComplete(() => pending.remove(call)));
    });

    await completed.future;
    latencies.sort();
    return _PacedMetrics(
      _percentile(latencies, 0.95),
      _percentile(latencies, 0.99),
      peakQueueDepth,
    );
  } finally {
    await worker.dispose();
  }
}

List<Float32List> _completeFrames(Float32List samples, int frameLength) {
  final frames = <Float32List>[
    for (var offset = 0; offset + frameLength <= samples.length; offset += frameLength)
      Float32List.sublistView(samples, offset, offset + frameLength),
  ];
  if (frames.isEmpty) throw StateError('Audio contains no complete $frameLength-sample frames.');
  return frames;
}

int _percentile(List<int> sortedValues, double percentile) {
  final index = (sortedValues.length * percentile).ceil() - 1;
  return sortedValues[index.clamp(0, sortedValues.length - 1)];
}

final class _SecondsEmitter implements ScoreEmitter {
  const _SecondsEmitter();

  @override
  void emit(String name, double value) => print('$name: ${value / Duration.microsecondsPerSecond} sec.');
}

final class _PacedMetrics {
  const _PacedMetrics(this.p95Micros, this.p99Micros, this.peakQueueDepth);

  final int p95Micros;
  final int p99Micros;
  final int peakQueueDepth;
}

final class _PcmWav {
  const _PcmWav(this.sampleRate, this.samples);

  final int sampleRate;
  final Float32List samples;
}

_PcmWav _loadWav(String path) {
  final bytes = File(path).readAsBytesSync();
  if (bytes.length < 12 ||
      ascii.decode(bytes.sublist(0, 4)) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('Not a RIFF/WAVE file.');
  }

  final data = ByteData.sublistView(bytes);
  int? sampleRate;
  int? channels;
  int? dataOffset;
  int? dataLength;
  for (var offset = 12; offset + 8 <= bytes.length;) {
    final chunkLength = data.getUint32(offset + 4, Endian.little);
    final contentOffset = offset + 8;
    if (contentOffset + chunkLength > bytes.length) throw const FormatException('Truncated WAV chunk.');
    final chunkId = ascii.decode(bytes.sublist(offset, offset + 4));
    if (chunkId == 'fmt ') {
      if (chunkLength < 16 ||
          data.getUint16(contentOffset, Endian.little) != 1 ||
          data.getUint16(contentOffset + 14, Endian.little) != 16) {
        throw const FormatException('Expected 16-bit PCM WAV audio.');
      }
      channels = data.getUint16(contentOffset + 2, Endian.little);
      sampleRate = data.getUint32(contentOffset + 4, Endian.little);
    } else if (chunkId == 'data') {
      dataOffset = contentOffset;
      dataLength = chunkLength;
    }
    offset = contentOffset + chunkLength + chunkLength.remainder(2);
  }

  if (sampleRate != 48000 ||
      channels == null ||
      channels == 0 ||
      dataOffset == null ||
      dataLength == null ||
      dataLength % (channels * 2) != 0) {
    throw const FormatException('Expected valid 48 kHz 16-bit PCM WAV audio.');
  }

  final samples = Float32List(dataLength ~/ (channels * 2));
  for (var frame = 0; frame < samples.length; frame++) {
    var sum = 0;
    for (var channel = 0; channel < channels; channel++) {
      sum += data.getInt16(dataOffset + (frame * channels + channel) * 2, Endian.little);
    }
    samples[frame] = sum / (channels * 32768.0);
  }
  return _PcmWav(sampleRate!, samples);
}

Uint8List _encodeMonoPcm16Wav(Float32List samples, {required int sampleRate}) {
  final dataLength = samples.length * 2;
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  data.setUint32(4, 36 + dataLength, Endian.little);
  bytes.setRange(8, 12, ascii.encode('WAVE'));
  bytes.setRange(12, 16, ascii.encode('fmt '));
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  data.setUint32(40, dataLength, Endian.little);
  for (var index = 0; index < samples.length; index++) {
    final clamped = samples[index].clamp(-1.0, 1.0);
    final pcm = clamped == 1.0 ? 32767 : (clamped * 32768).round();
    data.setInt16(44 + index * 2, pcm, Endian.little);
  }
  return bytes;
}

void main() async {
  await _runBenchmarks();
  exit(0);
}
