import 'dart:io';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:deepfilternet/deepfilternet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import 'wav_codec.dart';

void main() => runApp(const DeepFilterNetExample());

class DeepFilterNetExample extends StatelessWidget {
  const DeepFilterNetExample({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepFilterNet example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const SmokeTestPage(),
    );
  }
}

class SmokeTestPage extends StatefulWidget {
  const SmokeTestPage({super.key});

  @override
  State<SmokeTestPage> createState() => _SmokeTestPageState();
}

class _SmokeTestPageState extends State<SmokeTestPage> {
  String _status = 'Ready to enhance the bundled 48 kHz mono WAV.';
  bool _running = false;

  int progress = 0;

  Future<void> _enhance() async {
    setState(() {
      progress = 0;
      _running = true;
      _status = 'Loading noisy_sample.wav…';
    });

    DeepFilterNetWorker? filter;
    try {
      final asset = await rootBundle.load('assets/long-noisy-speech.wav');
      final sourceBytes = asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);

      debugPrint('loaded source audio: ${sourceBytes.length}');

      final wavBytes = await AudioDecoder.convertToWavBytes(
        sourceBytes,
        formatHint: 'wav',
        sampleRate: 48000,
        channels: 1,
        bitDepth: 16,
      );
      final wav = decodeMonoPcm16Wav(wavBytes);

      debugPrint('converted to wav: ${wav.samples.length}');

      await DeepFilterNet.initialize();
      filter = await .spawn(logLevel: .debug);
      debugPrint('created dfnet');

      final enhanced = Float32List(wav.samples.length);
      final frameLength = filter.frameLength;

      debugPrint('enhancing audio');

      for (var offset = 0; offset < wav.samples.length; offset += frameLength) {
        final validLength = (wav.samples.length - offset).clamp(0, frameLength);
        final frame = Float32List(frameLength);
        frame.setRange(0, validLength, wav.samples, offset);
        final processed = await filter.process(frame);
        enhanced.setRange(offset, offset + validLength, processed);

        setState(() {
          progress = ((offset / wav.samples.length) * 100).toInt();
          _running = true;
          _status = 'Loading noisy_sample.wav…';
        });
      }
      debugPrint('enhancing audio done');

      final fileBytes = encodeMonoPcm16Wav(enhanced, sampleRate: wav.sampleRate);

      if (!mounted) return;
      if (kIsWeb) {
        setState(() => _status = 'Enhanced WAV processed. Web download is not implemented yet.');

        downloadWeb(fileBytes);
      } else {
        final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}.deepfilternet${Platform.pathSeparator}');
        final output = File('${dir.path}deepfilternet_enhanced.wav');

        await dir.create(recursive: true);
        await output.writeAsBytes(encodeMonoPcm16Wav(enhanced, sampleRate: wav.sampleRate), flush: true);

        if (!mounted) return;
        setState(() => _status = 'Enhanced WAV written to ${output.path}');
      }
    } catch (error, stackTrace) {
      debugPrintStack(stackTrace: stackTrace, label: '$error');
      if (!mounted) return;
      setState(() => _status = 'Smoke test failed: $error');
    } finally {
      filter?.dispose();
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DeepFilterNet smoke test')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 24),

            FilledButton(
              onPressed: _running ? null : _enhance,
              child: Text(_running ? 'Enhancing ($progress%)' : 'Run smoke test'),
            ),
          ],
        ),
      ),
    );
  }
}

void downloadWeb(Uint8List bytes) {
  final blob = web.Blob([bytes.toJS].toJS);
  final url = web.URL.createObjectURL(blob);

  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = 'enhanced.wav'
    ..style.display = 'none';

  web.document.body?.appendChild(link);
  link.click();

  web.document.body?.removeChild(link);
  web.URL.revokeObjectURL(url);
}
