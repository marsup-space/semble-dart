// Quick end-to-end demo: parse a real Dart file via tree-sitter
// and print the top-level named children. Run with:
//
//   cd /Users/wuhao/Projects/crux/semble-dart
//   dart run example/chunk_demo.dart <path-to-dart-file>

import 'dart:io';

import 'package:semble_dart/semble_dart.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/chunk_demo.dart <dart-file>');
    exit(64);
  }
  final path = args.first;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('file not found: $path');
    exit(1);
  }

  // Resolve grammar from the file's extension.
  final grammar = LanguageRegistry.require(path);
  print('grammar: $grammar  (from $path)');

  // Open libcrux_grammars.dylib.
  final ts = await TreeSitter.load();
  ts.registerLanguage(grammar);
  print('loaded: ${ts.hasLanguage(grammar)}');

  // Read + parse the file.
  final source = file.readAsStringSync();
  final tree = ts.parse(source, language: grammar);
  try {
    final root = tree.root();
    final n = ts.childCount(root);
    print('root child count: $n (named: ${ts.namedChildCount(root)})');

    print('');
    print('=== top-level children ===');
    for (final child in ts.namedChildrenOf(root)) {
      final type = ts.nodeTypeString(child);
      final start = ts.startByte(child);
      final end = ts.endByte(child);
      final preview = source.substring(
        start,
        end > start + 80 ? start + 80 : end,
      ).replaceAll('\n', '\\n');
      print('  $type  [$start..$end]  $preview…');
    }
  } finally {
    tree.close();
    ts.close();
  }
}