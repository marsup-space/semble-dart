import 'package:semble_dart/src/chunker.dart';
import 'package:semble_dart/src/index.dart';
import 'package:test/test.dart';

void main() {
  CodeChunk chunk({
    required String filePath,
    required String content,
    int startLine = 1,
    int endLine = 3,
    bool isDefinition = true,
  }) {
    return CodeChunk(
      filePath: filePath,
      language: 'dart',
      startLine: startLine,
      endLine: endLine,
      startByte: 0,
      endByte: content.length,
      content: content,
      nodeType: isDefinition ? 'function_signature' : 'statement',
      isDefinition: isDefinition,
    );
  }

  test('search ranks lexical code chunks and preserves output schema', () {
    final index = SembleIndex.fromChunks([
      chunk(
        filePath: 'lib/auth.dart',
        content: 'class AuthClient { Future<void> refreshToken() async {} }',
      ),
      chunk(
        filePath: 'lib/theme.dart',
        content: 'class ThemePalette { int primaryColor = 0; }',
      ),
    ]);

    final results = index.search('refresh token', topK: 1);

    expect(results, hasLength(1));
    expect(results.single.filePath, 'lib/auth.dart');
    expect(results.single.toJson(), containsPair('file_path', 'lib/auth.dart'));
  });

  test('findRelated returns nearby chunks without returning the anchor', () {
    final index = SembleIndex.fromChunks([
      chunk(
        filePath: 'lib/a.dart',
        startLine: 1,
        content: 'class ConfigParser { void parseConfig() {} }',
      ),
      chunk(
        filePath: 'lib/b.dart',
        startLine: 10,
        content: 'class ConfigReader { void loadConfig() {} }',
      ),
      chunk(
        filePath: 'lib/c.dart',
        startLine: 20,
        content: 'class ButtonPainter { void paintButton() {} }',
      ),
    ]);

    final results = index.findRelated(file: 'lib/a.dart', line: 1, topK: 2);

    expect(results.map((r) => r.filePath), contains('lib/b.dart'));
    expect(results.map((r) => r.filePath), isNot(contains('lib/a.dart')));
  });

  test('empty and missing queries return no results', () {
    final index = SembleIndex.fromChunks([
      chunk(filePath: 'lib/a.dart', content: 'class Thing {}'),
    ]);

    expect(index.search(''), isEmpty);
    expect(index.search('not present'), isEmpty);
    expect(index.findRelated(file: 'missing.dart', line: 1), isEmpty);
  });
}
