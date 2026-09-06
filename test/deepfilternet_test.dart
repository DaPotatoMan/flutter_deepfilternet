import 'package:deepfilternet/deepfilternet.dart';
import 'package:test/test.dart';

void main() {
  test('exposes the processor factory without loading native code', () {
    expect(DeepFilterNet.create, isA<Function>());
  });
}
