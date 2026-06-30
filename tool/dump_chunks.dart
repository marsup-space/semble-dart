// Dump chunk boundaries for a single file so we can byte-compare with Python.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:semble_dart/semble_dart.dart';
import 'package:semble_dart/src/treesitter/bindings.dart';
import 'package:semble_dart/src/treesitter/languages.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/dump_chunks.dart <file>');
    exit(64);
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('not found: ${file.path}');
    exit(1);
  }

  final ext = Platform.isMacOS ? 'dylib' : Platform.isLinux ? 'so' : 'dll';
  final target = Platform.isMacOS ? 'macos-arm64' : 'linux-x64';
  var dylibPath = '';
  var dir = Directory.current;
  for (var i = 0; i < 8 && dir != null; i++) {
    final candidate =
        p.join(dir.path, 'third_party', 'bin', target, 'libcrux_grammars.$ext');
    if (File(candidate).existsSync()) {
      dylibPath = candidate;
      break;
    }
    dir = dir.parent;
  }
  final ts = await TreeSitter.load(path: dylibPath);
  final lang = LanguageRegistry.require(file.path);
  ts.registerLanguage(lang);
  final parser = TreeSitterParser(ts);
  final chunker = AstChunker(treeSitter: ts);

  final source = file.readAsStringSync();
  final parsed = parser.parseSource(path: file.path, source: source);
  try {
    final chunks = chunker.chunk(parsed);
    print('file: ${file.path}');
    print('language: $lang');
    print('source bytes: ${source.length}');
    print('chunks: ${chunks.length}');
    print('');
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      final h = c.content.hashCode.toRadixString(16);
      print('--- chunk $i ---');
      print('  lines: ${c.startLine}-${c.endLine}  bytes: ${c.startByte}-${c.endByte}  len: ${c.content.length}  hash: 0x$h  type: ${c.nodeType}  isDef: ${c.isDefinition}');
      print(c.content.length > 200
          ? '  ${c.content.substring(0, 200)}…'
          : '  ${c.content}');
    }
  } finally {
    parsed.close();
    ts.close();
  }
}
