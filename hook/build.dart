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

    final lib = _NativeLibraryTarget(input);
    final localFile = await lib.loadLibrary();

    output.assets.code.add(
      .new(
        package: input.packageName,
        name: _assetId,
        linkMode: DynamicLoadingBundled(),
        file: localFile.uri,
      ),
    );
  });
}

class _NativeLibraryTarget(final BuildInput input) {
  final CodeConfig config = input.config.code;

  late final cacheDirectory = Directory.fromUri(
    input.outputDirectory.resolve('native_cache/'),
  );

  OS get os => config.targetOS;
  Architecture get arch => config.targetArchitecture;

  /// The Rust target triple for the selected platform.
  String get rustTargetTriple {
    return switch (arch) {
      // Android
      .arm64 when os == .android => 'aarch64-linux-android',
      .arm when os == .android => 'armv7-linux-androideabi',
      .x64 when os == .android => 'x86_64-linux-android',

      // iOS
      .arm64 when os == .iOS =>
        config.iOS.targetSdk == .iPhoneSimulator ? 'aarch64-apple-ios-sim' : 'aarch64-apple-ios',
      _ when os == .iOS => throw UnsupportedError('No iOS binary is published for $arch.'),

      // macOS
      .arm64 when os == .macOS => 'aarch64-apple-darwin',
      .x64 when os == .macOS => 'x86_64-apple-darwin',

      // Linux
      .x64 when os == .linux => 'x86_64-unknown-linux-gnu',
      .arm64 when os == .linux => 'aarch64-unknown-linux-gnu',

      // Windows
      .x64 when os == .windows => 'x86_64-pc-windows-msvc',

      // TODO: Add support for Windows arm64 (aarch64-pc-windows-msvc)
      // Currently blocked due to older tract version (https://github.com/Rikorose/DeepFilterNet/issues/707)
      // Can be fixed by this PR: https://github.com/Rikorose/DeepFilterNet/pull/695
      .arm64 when os == .windows => throw UnsupportedError('Windows arm64 is not supported yet.'),

      _ => throw UnsupportedError('No libdf binary is published for $os/$arch.'),
    };
  }

  /// The native library filename for the selected operating system.
  String get fileName {
    return switch (os) {
      .android || .linux => 'libdf.so',
      .iOS || .macOS => 'libdf.dylib',
      .windows => 'df.dll',
      _ => throw UnsupportedError('DeepFilterNet does not support $os.'),
    };
  }

  String get iosSliceName {
    final targetTriple = rustTargetTriple;
    return targetTriple == 'aarch64-apple-ios-sim' ? 'ios-arm64-simulator' : 'ios-arm64';
  }

  /// Loads the native library for this build target into the local cache.
  Future<File> loadLibrary() async {
    await cacheDirectory.create(recursive: true);

    if (os == .iOS) {
      return _loadCachedLibrary(
        assetName: 'DeepFilter.xcframework.zip',
        fileName: 'libdf.dylib',
        extractLibrary: (bytes) => _extractIosLibrary(bytes, iosSliceName),
      );
    }

    return _loadCachedLibrary(
      assetName: 'libdf-$rustTargetTriple-$fileName',
      fileName: fileName,
      extractLibrary: (bytes) => bytes,
    );
  }

  /// Downloads, extracts, and caches one native library asset.
  Future<File> _loadCachedLibrary({
    required String assetName,
    required String fileName,
    required List<int> Function(Uint8List bytes) extractLibrary,
  }) async {
    final file = _AtomicFile.at([cacheDirectory.path, fileName]);
    if (file.existsSync()) return file;

    final bytes = await _ReleaseDownloader.load(cacheDirectory, assetName);

    return await file.write(extractLibrary(bytes));
  }

  /// Extracts the matching dylib slice from the iOS XCFramework archive.
  List<int> _extractIosLibrary(Uint8List zipBytes, String expectedSlice) {
    const assetName = 'DeepFilter.xcframework.zip';
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    final candidates = archive.files.where(
      (file) => file.isFile && file.name.endsWith('/libdf.dylib') && file.name.contains('/$expectedSlice/'),
    );
    if (candidates.length != 1) {
      throw StateError(
        'Expected one $expectedSlice libdf.dylib in $assetName, '
        'found ${candidates.length}.',
      );
    }
    return candidates.single.content;
  }
}

class _ReleaseDownloader {
  /// Loads and verifies a release asset using the cached checksum manifest.
  static Future<Uint8List> load(Directory cacheDirectory, String assetName) async {
    return verified(assetName, await checksums(cacheDirectory));
  }

  /// Loads the published checksum manifest, caching it locally.
  static Future<Map<String, String>> checksums(Directory cacheDirectory) async {
    final checksumFile = _AtomicFile.at([
      cacheDirectory.path,
      'SHA256SUMS.txt',
    ]);

    final bytes = checksumFile.existsSync()
        ? await checksumFile.readAsBytes()
        : await download('$releaseBase/SHA256SUMS.txt');

    if (!checksumFile.existsSync()) {
      await checksumFile.write(bytes);
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

  /// Downloads a release asset and verifies its SHA-256 checksum.
  static Future<Uint8List> verified(String assetName, Map<String, String> checksums) async {
    final expectedHash = checksums[assetName];

    if (expectedHash == null) {
      throw StateError('No checksum published for $assetName.');
    }

    final bytes = await download('$releaseBase/$assetName');
    final actualHash = sha256.convert(bytes).toString();

    if (actualHash != expectedHash) {
      throw StateError('Checksum mismatch for $assetName: expected $expectedHash, got $actualHash.');
    }

    return bytes;
  }

  /// Downloads bytes from [url].
  static Future<Uint8List> download(String url) async {
    final client = HttpClient();

    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'deepfilternet-build-hook');
      final response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('Download failed with HTTP ${response.statusCode}', uri: .parse(url));
      }

      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add);

      return builder.takeBytes();
    } finally {
      client.close();
    }
  }
}

extension type _AtomicFile(File file) implements File {
  factory at(List<String> parts) {
    return .new(File(parts.join(Platform.pathSeparator)));
  }

  /// Atomically write contents to this [file]
  Future<_AtomicFile> write(List<int> bytes) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);

    return this;
  }
}
