import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const releaseTag = 'libdf-v0.5.6-capi';
const releaseBase = 'https://github.com/dapotatoman/flutter_deepfilternet/releases/download/$releaseTag';
const _assetId = 'src/df_bindings_generated.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final config = input.config.code;
    final os = config.targetOS;
    final arch = config.targetArchitecture;
    final triple = _rustTriple(os, arch, config: config);
    final cacheDirectory = Directory.fromUri(
      input.outputDirectory.resolve('native_cache/'),
    );
    await cacheDirectory.create(recursive: true);

    final localFile = os == OS.iOS
        ? await _iosLibrary(cacheDirectory, triple)
        : await _flatLibrary(os, cacheDirectory, triple);

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetId,
        linkMode: DynamicLoadingBundled(),
        file: localFile.uri,
      ),
    );
  });
}

Future<File> _flatLibrary(
  OS os,
  Directory cacheDirectory,
  String triple,
) async {
  final fileName = _libFileName(os);
  final assetName = 'libdf-$triple-$fileName';
  final localFile = File(
    '${cacheDirectory.path}${Platform.pathSeparator}$fileName',
  );
  if (localFile.existsSync()) {
    return localFile;
  }

  final checksums = await _fetchChecksums(cacheDirectory);
  final bytes = await _downloadVerified(assetName, checksums);
  await _writeAtomically(localFile, bytes);
  return localFile;
}

Future<File> _iosLibrary(Directory cacheDirectory, String triple) async {
  const assetName = 'DeepFilter.xcframework.zip';
  final localFile = File(
    '${cacheDirectory.path}${Platform.pathSeparator}libdf.dylib',
  );
  if (localFile.existsSync()) return localFile;

  final checksums = await _fetchChecksums(cacheDirectory);
  final zipBytes = await _downloadVerified(assetName, checksums);
  final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
  final expectedSlice = triple == 'aarch64-apple-ios-sim' ? 'ios-arm64-simulator' : 'ios-arm64';
  final candidates = archive.files.where(
    (file) => file.isFile && file.name.endsWith('/libdf.dylib') && file.name.contains('/$expectedSlice/'),
  );
  if (candidates.length != 1) {
    throw StateError(
      'Expected one $expectedSlice libdf.dylib in $assetName, '
      'found ${candidates.length}.',
    );
  }
  await _writeAtomically(localFile, candidates.single.content);
  return localFile;
}

Future<Map<String, String>> _fetchChecksums(Directory cacheDirectory) async {
  final checksumFile = File(
    '${cacheDirectory.path}${Platform.pathSeparator}SHA256SUMS.txt',
  );
  final bytes = checksumFile.existsSync()
      ? await checksumFile.readAsBytes()
      : await _download('$releaseBase/SHA256SUMS.txt');
  if (!checksumFile.existsSync()) {
    await _writeAtomically(checksumFile, bytes);
  }

  final checksums = <String, String>{};
  for (final line in utf8.decode(bytes).split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(parts[0])) {
      throw FormatException('Invalid SHA256SUMS.txt line: $line');
    }
    checksums[parts.last.replaceFirst(RegExp(r'^\*'), '')] = parts.first.toLowerCase();
  }
  return checksums;
}

Future<Uint8List> _downloadVerified(
  String assetName,
  Map<String, String> checksums,
) async {
  final expectedHash = checksums[assetName];
  if (expectedHash == null) {
    throw StateError('No checksum published for $assetName.');
  }
  final bytes = await _download('$releaseBase/$assetName');
  final actualHash = sha256.convert(bytes).toString();
  if (actualHash != expectedHash) {
    throw StateError(
      'Checksum mismatch for $assetName: expected $expectedHash, '
      'got $actualHash.',
    );
  }
  return bytes;
}

Future<Uint8List> _download(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'deepfilternet-build-hook',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Download failed with HTTP ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);

    return builder.takeBytes();
  } finally {
    client.close();
  }
}

Future<void> _writeAtomically(File destination, List<int> bytes) async {
  final temporary = File('${destination.path}.tmp');
  await temporary.writeAsBytes(bytes, flush: true);
  await temporary.rename(destination.path);
}

String _rustTriple(OS os, Architecture arch, {required CodeConfig config}) {
  return switch (arch) {
    // Android
    .arm64 when os == .android => 'aarch64-linux-android',
    .arm when os == .android => 'armv7-linux-androideabi',
    .x64 when os == .android => 'x86_64-linux-android',

    // iOS
    .arm64 when os == .iOS => config.iOS.targetSdk == .iPhoneSimulator ? 'aarch64-apple-ios-sim' : 'aarch64-apple-ios',
    _ when os == .iOS => throw UnsupportedError('No iOS binary is published for $arch.'),

    // macOS
    .arm64 when os == .macOS => 'aarch64-apple-darwin',
    .x64 when os == .macOS => 'x86_64-apple-darwin',

    // Linux/Windows
    .x64 when os == .linux => 'x86_64-unknown-linux-gnu',
    .x64 when os == .windows => 'x86_64-pc-windows-msvc',

    _ => throw UnsupportedError('No libdf binary is published for $os/$arch.'),
  };
}

String _libFileName(OS os) {
  if (os == OS.android || os == OS.linux) return 'libdf.so';
  if (os == OS.iOS || os == OS.macOS) return 'libdf.dylib';
  if (os == OS.windows) return 'df.dll';
  throw UnsupportedError('DeepFilterNet does not support $os.');
}
