import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main() async {
  final crateDir = Directory(_getPath('native/DeepFilterNet/libDF'));

  if (!crateDir.existsSync()) {
    throw StateError(
      'Run this tool from the package root; could not find '
      '${crateDir.path}.',
    );
  }

  // Run build with git patches
  await _applyPatches(
    patchDir: _getPath('native/patches'),
    sourceDir: crateDir.path,
    task: () => _runProcess(
      'wasm-pack',
      ['build', '--target', 'web', '--release', '--features', 'wasm'],
      errorMessage: 'Web Wasm build failed.',
      cwd: crateDir.path,
      env: {'RUSTFLAGS': '-C target-feature=+simd128'},
    ),
  );

  // Copy generated assets
  {
    const assets = ['df.js', 'df_bg.wasm'];
    final outputDir = Directory(_getPath('pkg', base: crateDir.path));
    final assetsDir = Directory(_getPath('assets/web'));

    await assetsDir.create(recursive: true);

    for (final asset in assets) {
      final source = File(_getPath(asset, base: outputDir.path));

      if (!source.existsSync()) {
        throw StateError('wasm-pack did not generate ${source.path}.');
      }

      await source.copy(_getPath(asset, base: assetsDir.path));
    }
  }
}

String _getPath(String path, {String? base}) {
  base ??= Directory.current.path;
  return p.joinAll('$base/$path'.split('/'));
}

Future<void> _runProcess(
  String command,
  List<String> args, {
  required String errorMessage,
  Map<String, String>? env,
  String? cwd,
}) async {
  final process = await Process.start(
    command,
    args,
    workingDirectory: cwd,
    environment: env,
    runInShell: Platform.isWindows,
  );

  process
    ..stdout.transform(utf8.decoder).listen(print)
    ..stderr.transform(utf8.decoder).listen(print);

  if (await process.exitCode case final code when code != 0) {
    throw ProcessException(command, args, errorMessage, code);
  }
}

/// Applies `DeepFilterNet` submodule patches while building binaries
Future<void> _applyPatches({
  required Future<void> Function() task,

  /// Directory path that contains all patches
  required String patchDir,

  /// Where patches are to be applied
  required String sourceDir,
}) async {
  Future<void> cleanup() {
    return _runProcess(
      'git',
      ['reset', '--hard', 'origin/main'],
      cwd: _getPath('native/DeepFilterNet'),
      errorMessage: 'Could not apply the git patch.',
    );
  }

  try {
    await cleanup();

    // Apply patches
    {
      final list = Directory(patchDir).listSync();

      for (final patch in list) {
        final path = patch.absolute.path;

        await _runProcess(
          'git',
          ['apply', '--unidiff-zero', path],
          cwd: sourceDir,
          errorMessage: 'Could not apply the git patch: $path',
        );
      }
    }

    await task();
  } finally {
    await cleanup();
  }
}
