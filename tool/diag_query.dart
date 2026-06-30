// Per-query BM25 diagnostic: for one query, print each candidate's
// BM25 score + which terms hit + which path tokens hit, so we can
// see what the BM25 side of the pipeline is doing.
//
//   dart run tool/diag_query.dart "<query>" <repo-path>
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:semble_dart/semble_dart.dart';
import 'package:semble_dart/src/identifier_stemmer.dart';
import 'package:semble_dart/src/sparse.dart';
import 'package:semble_dart/src/treesitter/bindings.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/diag_query.dart "<query>" <repo>');
    exit(64);
  }
  final query = args[0];
  final repo = args[1];
  if (!Directory(repo).existsSync()) {
    stderr.writeln('repo not found: $repo');
    exit(1);
  }

  final ext = Platform.isMacOS ? 'dylib' : Platform.isLinux ? 'so' : 'dll';
  final target = Platform.isMacOS ? 'macos-arm64' : 'linux-x64';
  var dylibPath = '';
  var dir = Directory.current;
  for (var i = 0; i < 8 && dir != null; i++) {
    final candidate = p.join(dir.path, 'third_party', 'bin', target,
        'libcrux_grammars.$ext');
    if (File(candidate).existsSync()) {
      dylibPath = candidate;
      break;
    }
    dir = dir.parent;
  }
  if (dylibPath.isEmpty) {
    stderr.writeln('dylib not found');
    exit(1);
  }

  final ts = await TreeSitter.load(path: dylibPath);
  for (final lang in const [
    'dart', 'python', 'rust', 'typescript', 'tsx', 'go',
    'javascript', 'cpp', 'ruby', 'php',
  ]) {
    ts.registerLanguage(lang);
  }
  final parser = TreeSitterParser(ts);
  final chunker = AstChunker(treeSitter: ts);
  final stemmer = const IdentifierStemmer();

  final index = await SembleIndex.fromPath(
    rootPath: repo,
    parser: parser,
    chunker: chunker,
  );

  final queryStems = stemmer.tokenizeText(query);
  final bm25 = index.bm25;

  // Per-chunk: BM25 score, query terms that hit, path tokens that hit.
  final rows = <List<dynamic>>[];
  for (var i = 0; i < index.chunks.length; i++) {
    final stems = index.stems[i];
    final hitTerms = <String>[];
    double score = 0;
    final seen = <String>{};
    for (final term in queryStems) {
      if (!seen.add(term)) continue;
      final f = stems.where((s) => s == term).length;
      if (f == 0) continue;
      hitTerms.add('$term×$f');
      final df = bm25.df[term] ?? 0;
      if (df == 0) continue;
      final idf = math.log(1 + (bm25.numDocs - df + 0.5) / (df + 0.5));
      final tfNorm = f * (1.5 + 1) /
          (f + 1.5 * (1 - 0.75 + 0.75 * bm25.docLengths[i] / bm25.avgDocLength));
      score += idf * tfNorm;
    }
    // Path tokens (file stem + last 3 dirs)
    final pathText = enrichForBm25(content: '', filePath: index.chunks[i].filePath).trim();
    final pathTokens = stemmer.tokenizeText(pathText);
    final pathHits = <String>[];
    for (final term in queryStems) {
      if (pathTokens.contains(term)) pathHits.add(term);
    }
    rows.add([i, index.chunks[i].filePath, score, hitTerms, pathHits, bm25.docLengths[i]]);
  }
  rows.sort((a, b) => (b[2] as double).compareTo(a[2] as double));

  print('=== query: "$query" ===');
  print('stems: $queryStems');
  print('');
  print('top 15 BM25 candidates:');
  print('${'rank'.padLeft(4)} | ${'file'.padRight(50)} | ${'bm25'.padLeft(7)} '
      '| ${'docLen'.padLeft(6)} | term hits / path hits');
  for (var k = 0; k < 15 && k < rows.length; k++) {
    final row = rows[k];
    final path = (row[1] as String).length > 50
        ? '...' + (row[1] as String).substring((row[1] as String).length - 47)
        : row[1] as String;
    final hits = (row[3] as List).join(',');
    final pathHits = (row[4] as List).join(',');
    print(
        '${k.toString().padLeft(4)} | ${path.padRight(50)} | '
        '${(row[2] as double).toStringAsFixed(3).padLeft(7)} | '
        '${(row[5] as int).toString().padLeft(6)} | '
        '$hits  /  $pathHits');
  }
}

double _log(double x) {
  if (x <= 0) return 0;
  return math.log(x);
}
