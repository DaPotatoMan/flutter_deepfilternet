import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/services.dart';

class WebAsset {
  static const base = 'packages/deepfilternet/assets/web';

  /// Loads a js module using [importModule] from assets under [path]
  static Future<JSObject> import(String path) {
    return importModule(resolvePath(path).toJS).toDart;
  }

  static String resolvePath(String filename) {
    final path = ui_web.assetManager.getAssetUrl('$base/$filename');
    return Uri.base.resolve(path).toString();
  }

  static Future<ByteData> load(String filename) {
    return rootBundle.load('$base/$filename');
  }
}
