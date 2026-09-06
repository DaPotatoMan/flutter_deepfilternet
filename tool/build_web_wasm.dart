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
  await _applyGitPatch(
    patchPath: _getPath('native/patches/wasm-build.patch'),
    cwd: crateDir.path,
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
  final result = await Process.run(
    command,
    args,
    workingDirectory: cwd,
    environment: env,
    runInShell: Platform.isWindows,
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (result.exitCode != 0) {
    throw ProcessException(command, args, errorMessage, result.exitCode);
  }
}

Future<void> _applyGitPatch({
  required Future<void> Function() task,
  required String patchPath,
  required String cwd,
}) async {
  if (!File(patchPath).existsSync()) {
    throw StateError('Could not find git patch at: $patchPath');
  }

  await _runProcess('git', ['apply', patchPath], cwd: cwd, errorMessage: 'Could not apply the git patch.');

  try {
    await task();
  } finally {
    await _runProcess('git', ['apply', '-R', patchPath], cwd: cwd, errorMessage: 'Could not apply the git patch.');
  }
}
