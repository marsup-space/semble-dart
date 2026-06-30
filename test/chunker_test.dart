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
    chunker = AstChunker(treeSitter: ts, minChunkBytes: 0);
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
}
