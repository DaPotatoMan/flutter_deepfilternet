import 'dart:convert';
import 'dart:typed_data';

class MonoWav {
  const MonoWav({required this.sampleRate, required this.samples});

  final int sampleRate;
  final Float32List samples;
}

MonoWav decodeMonoPcm16Wav(Uint8List bytes) {
  if (bytes.length < 44 ||
      ascii.decode(bytes.sublist(0, 4)) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('Not a RIFF/WAVE file.');
  }

  final data = ByteData.sublistView(bytes);
  int? sampleRate;
  int? dataOffset;
  int? dataLength;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = ascii.decode(bytes.sublist(offset, offset + 4));
    final chunkLength = data.getUint32(offset + 4, Endian.little);
    final contentOffset = offset + 8;
    if (contentOffset + chunkLength > bytes.length) {
      throw const FormatException('Truncated WAV chunk.');
    }
    if (chunkId == 'fmt ') {
      if (chunkLength < 16 ||
          data.getUint16(contentOffset, Endian.little) != 1 ||
          data.getUint16(contentOffset + 2, Endian.little) != 1 ||
          data.getUint16(contentOffset + 14, Endian.little) != 16) {
        throw const FormatException('Expected mono 16-bit PCM WAV audio.');
      }
      sampleRate = data.getUint32(contentOffset + 4, Endian.little);
    } else if (chunkId == 'data') {
      dataOffset = contentOffset;
      dataLength = chunkLength;
    }
    offset = contentOffset + chunkLength + chunkLength.remainder(2);
  }

  if (sampleRate == null || dataOffset == null || dataLength == null) {
    throw const FormatException('WAV is missing fmt or data chunks.');
  }
  final samples = Float32List(dataLength ~/ 2);
  for (var index = 0; index < samples.length; index++) {
    samples[index] =
        data.getInt16(dataOffset + index * 2, Endian.little) / 32768.0;
  }
  return MonoWav(sampleRate: sampleRate, samples: samples);
}

Uint8List encodeMonoPcm16Wav(Float32List samples, {required int sampleRate}) {
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
