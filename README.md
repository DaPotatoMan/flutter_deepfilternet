# deepfilternet

Flutter FFI bindings for [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet),
providing real-time noise suppression for 48 kHz mono float32 audio. Native
assets build hooks download the correct prebuilt `libdf` library and bundle it
into Android, iOS, macOS, Windows, and Linux applications.

## Requirements

- Flutter 3.38 or newer
- Dart 3.10 or newer
- Network access to GitHub Releases on the first build for a target

Consuming applications do not need Rust, Cargo, cbindgen, or a native compiler.

## Usage

Create one stateful processor per audio stream, feed it frames of the exact
length reported by the model, and dispose it when finished:

```dart
final filter = DeepFilterNet.create(attenLimitDb: 100);
try {
  print(filter.frameLength); // 480 for the bundled DFN3 model.
  final Float32List enhanced = filter.process(inputFrame);
} finally {
  filter.dispose();
}
```

`inputFrame` must contain `frameLength` mono samples at 48 kHz. Processing is
synchronous and CPU-intensive; real applications should keep it off the UI
isolate. A custom compatible ONNX model tarball can be selected with
`DeepFilterNet.create(modelPath: path)`.

Native logs are opt-in and can be drained without retaining native memory:

```dart
final filter = DeepFilterNet.create(logLevel: DeepFilterNetLogLevel.info);
final message = filter.nextLogMessage(); // `null` when the queue is empty.
```

For this common case, `DeepFilterNetIsolate` owns a processor in a dedicated
worker isolate. Keep the worker alive for the stream rather than spawning one
per frame, and dispose it when finished:

```dart
final filter = await DeepFilterNetIsolate.spawn();
try {
  print(filter.frameLength); // 480 for the bundled DFN3 model.
  final enhanced = await filter.process(inputFrame);
} finally {
  await filter.dispose();
}
```

Each worker owns one stateful processor and processes submitted frames in
order. The frame buffer is transferred to the worker; callers must not reuse
the input `Float32List` after passing it to `process`.

## Web

Web builds use the packaged Wasm runtime and bundled DFN3 model in
`assets/web/`. Before creating a processor, load those assets once:

```dart
await DeepFilterNet.initialize();
final filter = DeepFilterNet.create(attenLimitDb: 100);
```

Web does not support `modelPath` or native log collection.
`DeepFilterNetIsolate` runs processing in a module Web Worker. The Wasm
runtime is about 8 MB and the bundled model is about 8 MB before compression
by the application host.

The example app reads its bundled 48 kHz mono PCM WAV, processes every frame,
pads and trims the final partial frame, and writes
`deepfilternet_enhanced.wav` to the platform temporary directory.

## Native binaries and integrity

There are no official upstream prebuilt C-API libraries for these targets.
The binaries used by this package are built by this repository's own GitHub
Actions workflow from the DeepFilterNet `v0.5.6-89-gd375b2d` submodule pin; they are not
distributed or supported by the upstream DeepFilterNet project. The workflow
enables the upstream `capi`, `default-model`, and `tract` features and applies
the checked-in `native/patches/use-embedded-model.patch` so the C API can use
the compiled-in model.

On its first build for a target, `hook/build.dart` downloads
`SHA256SUMS.txt`, downloads the matching release asset, verifies its SHA-256
digest, and only then makes it available for bundling. iOS downloads and
verifies the XCFramework ZIP before extracting the requested device or
simulator slice. There is no offline or vendored binary fallback in this
initial version. A previously populated native-assets build cache can be
reused, but a clean build on a new machine requires GitHub Releases access.

## Releasing native binaries

The `Build libdf` workflow runs on tags matching `libdf-v*`. To publish the
current binary set after configuring this repository's GitHub remote:

```sh
git tag libdf-v0.5.6-capi
git push origin libdf-v0.5.6-capi
```

The release must contain the target-prefixed Android and desktop libraries,
`DeepFilter.xcframework.zip`, and `SHA256SUMS.txt`. Do not move the tag after
consumers may have cached the release.

To bump DeepFilterNet:

1. Update the `native/DeepFilterNet` submodule to an exact upstream tag.
2. Rebase or remove the embedded-model patch as required by the new C API.
3. Regenerate `native/df.h` with cbindgen and regenerate
   `lib/src/df_bindings_generated.dart` with ffigen if the C API changed.
4. Run the CI workflow through a new `libdf-v*` tag.
5. Update `releaseTag` in `hook/build.dart` after that release is complete.

Never update `releaseTag` to assets that have not yet been published with a
complete checksum manifest.

## Development

The committed header is build-time metadata, so consumers do not need Rust:

```sh
cbindgen native/DeepFilterNet/libDF \
  --config cbindgen.toml \
  --output native/df.h
dart run ffigen --config ffigen.yaml
```

The example is a smoke-test harness, not proof that all targets work. Android
arm64, iOS simulator, iOS physical device, macOS, Windows, and Linux must each
be exercised after publishing the release before declaring a release fully
validated.
