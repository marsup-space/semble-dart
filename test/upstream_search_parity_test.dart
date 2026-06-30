import 'package:semble_dart/src/chunker.dart';
import 'package:semble_dart/src/index.dart';
import 'package:test/test.dart';

CodeChunk _chunk(String content, String filePath, {int startLine = 1}) {
  final lineCount = content.split('\n').length;
  return CodeChunk(
    filePath: filePath,
    language: 'python',
    startLine: startLine,
    endLine: startLine + lineCount - 1,
    startByte: 0,
    endByte: content.length,
    content: content,
    nodeType: content.startsWith('class ')
        ? 'class_definition'
        : 'function_definition',
    isDefinition: true,
  );
}

void main() {
  group('upstream test_search.py parity', () {
    late List<CodeChunk> chunks;
    late SembleIndex index;

    setUp(() {
      chunks = [
        _chunk(
          "def authenticate(token):\n    return token == 'secret'",
          'auth.py',
        ),
        _chunk(
          'def login(username, password):\n    pass',
          'auth.py',
          startLine: 4,
        ),
        _chunk('class UserService:\n    pass', 'users.py', startLine: 1),
        _chunk(
          'def format_date(dt):\n    return str(dt)',
          'utils.py',
          startLine: 1,
        ),
      ];
      index = SembleIndex.fromChunks(chunks);
    });

    test(
      'BM25 search returns the most relevant authentication chunk first',
      () {
        final results = index.search('authenticate token', topK: 4);
        expect(results, isNotEmpty);
        expect(results.first.content, contains('authenticate'));
      },
    );

    test('empty, whitespace, and token-less queries return empty results', () {
      for (final query in ['', '   ', '\n\n', 'zzzznonexistentterm']) {
        expect(index.search(query, topK: 3), isEmpty);
      }
    });

    test('topK is respected and result locations are unique', () {
      expect(
        index.search('function', topK: 1),
        hasLength(lessThanOrEqualTo(1)),
      );

      final results = index.search('authenticate', topK: 5);
      final locations = {
        for (final r in results) '${r.filePath}:${r.startLine}',
      };
      expect(results, hasLength(locations.length));
    });

    test('filterPaths restricts search to selected files', () {
      final results = index.search(
        'format',
        topK: 4,
        filterPaths: ['utils.py'],
      );
      expect(results, isNotEmpty);
      expect(results.every((r) => r.filePath == 'utils.py'), isTrue);
    });

    test('identical content in different files produces separate results', () {
      final duplicateIndex = SembleIndex.fromChunks([
        _chunk('def helper():\n    pass', 'module_a.py'),
        _chunk('def helper():\n    pass', 'module_b.py'),
      ]);

      final results = duplicateIndex.search('helper', topK: 5);
      expect(results.map((r) => r.filePath).toSet(), {
        'module_a.py',
        'module_b.py',
      });
    });

    test('findRelated excludes the anchor and returns related chunks', () {
      final results = index.findRelated(file: 'auth.py', line: 1, topK: 3);
      expect(results, hasLength(lessThanOrEqualTo(3)));
      expect(
        results.map((r) => '${r.filePath}:${r.startLine}'),
        isNot(contains('auth.py:1')),
      );
    });
  });
}
