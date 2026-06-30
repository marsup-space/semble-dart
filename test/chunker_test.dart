import 'dart:io';

import 'package:semble_dart/semble_dart.dart';
import 'package:test/test.dart';

const _skipMessage =
    'libcrux_grammars.<so|dylib|dll> not found in third_party/bin/<target>/ — '
    'run `dart run tool/build_native.dart` first';

Future<TreeSitter?> _loadIfAvailable() async {
  final ext = Platform.isMacOS
      ? 'dylib'
      : Platform.isLinux
      ? 'so'
      : Platform.isWindows
      ? 'dll'
      : null;
  if (ext == null) return null;
  final target = Platform.isMacOS ? 'macos-arm64' : 'linux-x64';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final p = '${dir.path}/third_party/bin/$target/libcrux_grammars.$ext';
    if (File(p).existsSync()) return TreeSitter.load(path: p);
    dir = dir.parent;
  }
  return null;
}

void main() {
  late TreeSitter ts;
  late TreeSitterParser parser;
  late AstChunker chunker;
  late bool available;

  setUpAll(() async {
    final loaded = await _loadIfAvailable();
    if (loaded == null) {
      available = false;
      return;
    }
    ts = loaded;
    parser = TreeSitterParser(ts);
    chunker = AstChunker(treeSitter: ts, desiredChunkBytes: 50);
    available = true;
  });

  tearDownAll(() {
    if (available) ts.close();
  });

  test('chunks Dart source into top-level AST ranges', () {
    if (!available) {
      markTestSkipped(_skipMessage);
      return;
    }
    const source = '''
class Greeter {
  void greet() {
    print("hi");
  }
}

void main() {
  Greeter().greet();
}
''';

    final parsed = parser.parseSource(path: 'lib/main.dart', source: source);
    try {
      final chunks = chunker.chunk(parsed);
      expect(chunks, isNotEmpty);
      expect(chunks.first.filePath, 'lib/main.dart');
      expect(chunks.first.language, 'dart');
      expect(chunks.first.startLine, 1);
      expect(chunks.first.content, contains('class Greeter'));
      expect(chunks.any((chunk) => chunk.isDefinition), isTrue);
    } finally {
      parsed.close();
    }
  });

  test('chunks Python source and preserves 1-based line ranges', () {
    if (!available) {
      markTestSkipped(_skipMessage);
      return;
    }
    const source = '''
def greet(name):
    return f"hi {name}"

class Runner:
    pass
''';

    final parsed = parser.parseSource(path: 'pkg/app.py', source: source);
    try {
      final chunks = chunker.chunk(parsed);
      expect(chunks, hasLength(greaterThanOrEqualTo(2)));
      expect(chunks.first.language, 'python');
      expect(chunks.first.startLine, 1);
      expect(chunks.first.endLine, greaterThanOrEqualTo(2));
      expect(chunks.first.content, contains('def greet'));
      expect(chunks.last.content, contains('class Runner'));
    } finally {
      parsed.close();
    }
  });

  test('chunks Python source with non-ASCII docstring at correct char '
      'offsets', () {
    // Regression test for the byte→char offset bug: a docstring
    // containing `→` (3 UTF-8 bytes = 1 char) used to slice the
    // chunk at the wrong position. After the fix, the chunk must
    // end exactly at the end of the function body, not two chars
    // past it.
    if (!available) {
      markTestSkipped(_skipMessage);
      return;
    }
    // Use a 750-byte chunker (production default) so a ~130-byte
    // file fits in a single chunk and we can assert exact boundaries.
    final bigChunker = AstChunker(treeSitter: ts);
    const source = 'def _rrf_scores(scores):\n'
        '    """Convert raw scores to RRF scores 1/(k + rank); '
        'higher raw score → rank 1."""\n'
        '    if not scores:\n'
        '        return scores\n'
        '    return {}\n';
    final parsed = parser.parseSource(path: 'lib/util.py', source: source);
    try {
      final chunks = bigChunker.chunk(parsed);
      expect(chunks, hasLength(1));
      // The whole file is 5 lines; the chunk must end at line 5.
      expect(chunks.first.endLine, 5);
      // The chunk's content must end with the closing `return {}`
      // line — not be cut short and not include phantom chars past
      // the `→`.
      expect(chunks.first.content, endsWith('return {}'));
      // Line range starts at 1.
      expect(chunks.first.startLine, 1);
    } finally {
      parsed.close();
    }
  });

  test('chunks Python source with multi-byte CJK identifiers correctly',
      () {
    // Identifiers containing CJK characters are multi-byte in UTF-8
    // (3 bytes per CJK char). The chunker must slice on char
    // boundaries, not byte boundaries, so the CJK chars are not
    // split mid-codepoint.
    if (!available) {
      markTestSkipped(_skipMessage);
      return;
    }
    final bigChunker = AstChunker(treeSitter: ts);
    const source = 'def 配置_解析(配置):\n'
        '    """解析配置 → 返回字典"""\n'
        '    return {"ok": True}\n';
    final parsed = parser.parseSource(path: 'lib/cfg.py', source: source);
    try {
      final chunks = bigChunker.chunk(parsed);
      expect(chunks, hasLength(1));
      // Content must include the CJK identifier intact (not split
      // mid-codepoint).
      expect(chunks.first.content, contains('配置_解析'));
      expect(chunks.first.content, contains('解析配置'));
      // The CJK char `→` must appear whole, not as garbage bytes.
      expect(chunks.first.content, contains('→'));
      // End at the last line.
      expect(chunks.first.endLine, 3);
    } finally {
      parsed.close();
    }
  });

  test('byte→char conversion is identity for pure-ASCII content', () {
    // Sanity check: the conversion is a no-op for ASCII (the
    // common case), so existing ASCII chunking behavior is
    // unchanged after the fix.
    if (!available) {
      markTestSkipped(_skipMessage);
      return;
    }
    final bigChunker = AstChunker(treeSitter: ts);
    const source = 'def foo():\n    return 1\n';
    final parsed = parser.parseSource(path: 'lib/foo.py', source: source);
    try {
      final chunks = bigChunker.chunk(parsed);
      expect(chunks, hasLength(1));
      expect(chunks.first.content, 'def foo():\n    return 1\n');
      expect(chunks.first.startLine, 1);
      expect(chunks.first.endLine, 2);
    } finally {
      parsed.close();
    }
  });
}
