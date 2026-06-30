// Smoke test for the tree-sitter FFI bindings. Loads the
// libcrux_grammars.dylib, registers Dart + Python grammars, and
// parses a tiny program in each. Verifies:
//
//   1. The dylib loads (all expected symbols resolve).
//   2. Grammar entry points are callable.
//   3. parse() returns a non-null tree with sensible byte ranges.
//   4. The root node has the expected type (e.g. 'program').
//   5. Walking named children yields real children.
//
// The test is skipped on platforms where the dylib isn't built.

import 'dart:io';

import 'package:semble_dart/src/treesitter/bindings.dart';
import 'package:semble_dart/src/treesitter/languages.dart';
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
  // Walk up from Directory.current (the test runner's cwd IS the
  // package root for `dart test`). Platform.script is unreliable
  // for the test runner.
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
  late bool available;

  setUpAll(() async {
    final t = await _loadIfAvailable();
    if (t == null) {
      available = false;
      return;
    }
    ts = t;
    ts.registerLanguage('dart');
    ts.registerLanguage('python');
    available = true;
  });

  tearDownAll(() {
    if (available) ts.close();
  });

  group('libcrux_grammars bindings', () {
    test('dylib + grammar registration smoke test', () {
      if (!available) {
        markTestSkipped(_skipMessage);
        return;
      }
      expect(ts.hasLanguage('dart'), isTrue);
      expect(ts.hasLanguage('python'), isTrue);
    });

    test('parse a tiny Dart program', () {
      if (!available) {
        markTestSkipped(_skipMessage);
        return;
      }
      const source = 'void main() { print("hi"); }';
      final tree = ts.parse(source, language: 'dart');
      try {
        final root = tree.root();
        expect(ts.nodeTypeString(root), 'program');
        expect(ts.startByte(root), 0);
        expect(ts.endByte(root), source.length);

        final topLevel = ts.namedChildrenOf(root);
        expect(topLevel, isNotEmpty);
        expect(ts.startByte(topLevel.first), 0);
        expect(ts.nodeTypeString(topLevel.first), isNotEmpty);
      } finally {
        tree.close();
      }
    });

    test('parse a tiny Python program', () {
      if (!available) {
        markTestSkipped(_skipMessage);
        return;
      }
      const source = 'def greet(name):\n    return f"hi {name}"\n';
      final tree = ts.parse(source, language: 'python');
      try {
        final root = tree.root();
        expect(ts.nodeTypeString(root), 'module');
        expect(ts.startByte(root), 0);
        expect(ts.endByte(root), source.length);

        final topLevel = ts.namedChildrenOf(root);
        expect(topLevel, hasLength(1));
        expect(ts.startByte(topLevel.first), 0);
        expect(ts.nodeTypeString(topLevel.first), 'function_definition');
      } finally {
        tree.close();
      }
    });

    test('LanguageRegistry.resolve maps common extensions', () {
      expect(LanguageRegistry.resolve('foo.dart'), 'dart');
      expect(LanguageRegistry.resolve('foo.py'), 'python');
      expect(LanguageRegistry.resolve('foo.ts'), 'typescript');
      expect(LanguageRegistry.resolve('foo.tsx'), 'tsx');
      expect(LanguageRegistry.resolve('foo.go'), 'go');
      expect(LanguageRegistry.resolve('foo.rs'), 'rust');
      expect(LanguageRegistry.resolve('foo.cpp'), 'cpp');
      expect(LanguageRegistry.resolve('foo.h'), 'cpp');
      expect(LanguageRegistry.resolve('foo.rb'), 'ruby');
      expect(LanguageRegistry.resolve('foo.php'), 'php');
      expect(LanguageRegistry.resolve('foo.phps'), 'php_only');
      // Path forms:
      expect(LanguageRegistry.resolve('/abs/path/to/foo.DART'), 'dart');
      expect(LanguageRegistry.resolve('./relative.TSX'), 'tsx');
      // Unsupported:
      expect(LanguageRegistry.resolve('foo.txt'), isNull);
      expect(LanguageRegistry.resolve('README'), isNull);
    });
  });
}
