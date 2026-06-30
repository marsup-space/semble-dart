import 'package:semble_dart/src/files.dart';
import 'package:test/test.dart';

void main() {
  test('SembleFiles recognizes supported code extensions', () {
    expect(SembleFiles.typeForPath('lib/main.dart')?.language, 'dart');
    expect(SembleFiles.typeForPath('src/app.py')?.language, 'python');
    expect(SembleFiles.typeForPath('web/main.tsx')?.language, 'tsx');
    expect(SembleFiles.typeForPath('include/foo.hpp')?.language, 'cpp');
  });

  test('SembleFiles rejects unsupported paths', () {
    expect(SembleFiles.typeForPath('README.md'), isNull);
    expect(SembleFiles.typeForPath('notes.txt'), isNull);
    expect(SembleFiles.isSupportedCodePath('image.png'), isFalse);
  });
}
