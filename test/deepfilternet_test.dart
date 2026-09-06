import 'package:deepfilternet/deepfilternet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exposes the processor factory without loading native code', () {
    expect(DeepFilterNet.create, isA<Function>());
  });
}
