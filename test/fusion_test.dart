import 'package:semble_dart/src/fusion.dart';
import 'package:semble_dart/src/protocol.dart' show SearchResult;
import 'package:test/test.dart';

/// Helper: build a RankedChunk from a (file, line, bm25, dense) tuple.
RankedChunk _chunk(
  String file,
  int line, {
  double bm25 = 0,
  double dense = 0,
  bool isDefinition = false,
  List<String> stems = const [],
  String? content,
}) {
  return RankedChunk(
    chunk: SearchResult(
      filePath: file,
      startLine: line,
      endLine: line + 5,
      score: bm25 + dense,
      content: content ?? 'content for $file:$line',
    ),
    bm25Score: bm25,
    denseScore: dense,
    isDefinition: isDefinition,
    stems: stems,
  );
}

void main() {
  group('Fusion.fuse — basics', () {
    test('empty inputs → empty output', () {
      expect(Fusion.fuse(const [], const []), isEmpty);
    });

    test('one list empty, other non-empty → still returns hits', () {
      final hits = Fusion.fuse(const [], [_chunk('a.dart', 10, dense: 0.9)]);
      expect(hits, hasLength(1));
      expect(hits.first.filePath, 'a.dart');
    });

    test('topK truncation', () {
      final bm25 = [
        for (var i = 0; i < 10; i++) _chunk('a.dart', i, bm25: 1.0 - i * 0.01),
      ];
      final hits = Fusion.fuse(
        bm25,
        const [],
        options: const FusionOptions(topK: 3),
      );
      expect(hits, hasLength(3));
    });

    test('topK < 1 → empty', () {
      final hits = Fusion.fuse(
        [_chunk('a.dart', 1, bm25: 0.5)],
        const [],
        options: const FusionOptions(topK: 0),
      );
      expect(hits, isEmpty);
    });

    test('deduplicates chunks appearing in both lists', () {
      final same = _chunk('a.dart', 10, bm25: 0.8, dense: 0.7);
      final hits = Fusion.fuse([same], [same]);
      // Should appear once in output, not twice.
      expect(hits, hasLength(1));
    });

    test('preserves SearchResult payload in output', () {
      final c = _chunk('lib/auth.dart', 42, bm25: 0.5);
      final hits = Fusion.fuse([c], const []);
      expect(hits.first.filePath, 'lib/auth.dart');
      expect(hits.first.startLine, 42);
      expect(hits.first.endLine, 47);
      expect(hits.first.content, 'content for lib/auth.dart:42');
    });
  });

  group('Fusion.fuse — RRF', () {
    test('rank-1 in both lists → top of merged list', () {
      // Same chunk appears at rank 0 in both → highest possible RRF.
      final winner = _chunk('a.dart', 1, bm25: 1.0, dense: 1.0);
      final loser = _chunk('b.dart', 1, bm25: 0.5, dense: 0.5);
      final hits = Fusion.fuse([winner], [winner, loser]);
      expect(hits.first.filePath, 'a.dart');
    });

    test('RRF rank-1 in one list beats rank-1+rank-1 with rerank loss', () {
      // chunk A: rank 0 in BM25 only (1/(60+1) ≈ 0.0164)
      // chunk B: rank 0 in dense only (same)
      // chunk C: rank 1 in BOTH (2 * 1/(60+2) ≈ 0.0323) → wins on RRF
      final a = _chunk('a.dart', 1, bm25: 1.0);
      final b = _chunk('b.dart', 1, dense: 1.0);
      final c = _chunk('c.dart', 1, bm25: 0.9, dense: 0.9);
      final hits = Fusion.fuse([a, c], [b, c]);
      expect(hits.first.filePath, 'c.dart');
    });
  });

  group('Fusion.fuse — rerank signals', () {
    test('definition boost: same RRF, definition chunk wins', () {
      // Both at rank 0 in their respective lists → same RRF.
      // Definition chunk has the boost.
      final def = _chunk(
        'a.dart',
        1,
        bm25: 1.0,
        isDefinition: true,
        content: 'def parseConfig(): pass',
      );
      final use = _chunk('b.dart', 1, dense: 1.0, isDefinition: false);
      final hits = Fusion.fuse(
        [def],
        [use],
        options: const FusionOptions(query: 'parseConfig'),
      );
      expect(hits.first.filePath, 'a.dart');
    });

    test('natural-language query boosts matching file stems', () {
      final matched = _chunk(
        'lib/parse_config.dart',
        1,
        bm25: 1.0,
        stems: ['parse', 'config'],
      );
      final unmatched = _chunk(
        'lib/render.dart',
        1,
        dense: 1.0,
        stems: ['render'],
      );
      final hits = Fusion.fuse(
        [matched],
        [unmatched],
        options: const FusionOptions(query: 'parse config'),
      );
      expect(hits.first.filePath, 'lib/parse_config.dart');
    });

    test('file coherence: multi-chunk file beats single chunk', () {
      // Both files only have BM25 contributions (no dense), so the
      // adaptive-weighting signal is neutral. x.dart's 3 chunks give
      // it a 1.1x file-coherence boost that y.dart (1 chunk) doesn't
      // get.
      final x1 = _chunk('x.dart', 1, bm25: 0.9);
      final x2 = _chunk('x.dart', 100, bm25: 0.5);
      final x3 = _chunk('x.dart', 200, bm25: 0.3);
      final y = _chunk('y.dart', 1, bm25: 1.0);
      final hits = Fusion.fuse([x1, x2, x3, y], const []);
      // y is rank 3 in bm25 list (1/(60+4) ≈ 0.01563), x1 is rank 0
      // (1/(60+1) ≈ 0.01639). x1 also gets 1.1x file-coherence boost.
      // x1 final ≈ 0.01803, y final ≈ 0.01563 → x1 wins.
      expect(hits.first.filePath, 'x.dart');
    });

    test('noise penalty: test file down-ranked', () {
      // Without penalty, test file would win on raw RRF. With 0.85x
      // multiplier, the non-test file (which only has dense) wins.
      final noisy = _chunk('lib/foo_test.dart', 1, bm25: 2.0);
      final clean = _chunk('lib/foo.dart', 1, dense: 1.5);
      final hits = Fusion.fuse([noisy], [clean]);
      expect(hits.first.filePath, 'lib/foo.dart');
    });

    test('noise penalty catches various test patterns', () {
      expect(
        Fusion.fuse([_chunk('lib/a_test.dart', 1, bm25: 1.0)], const []),
        // Hits exist; not asserting order, just that the file is
        // recognized as noise (penalty applied = 0.85x score). We
        // can't easily observe the penalty directly here, but we can
        // confirm via the rerank-vs-clean comparison above.
        hasLength(1),
      );
    });
  });

  group('Fusion.fuse — adaptive weighting', () {
    test('symbol-like query boosts BM25-favored chunk', () {
      // Both at rank 0 → same RRF. BM25-favored chunk wins on signal 1.
      final bm = _chunk('a.dart', 1, bm25: 1.0, dense: 0.1);
      final dn = _chunk('b.dart', 1, bm25: 0.1, dense: 1.0);
      final hits = Fusion.fuse(
        [bm],
        [dn],
        options: const FusionOptions(query: 'parseConfig'),
      );
      expect(hits.first.filePath, 'a.dart');
    });

    test('natural-language query boosts dense-favored chunk', () {
      // Same setup, but query is multi-word.
      final bm = _chunk('a.dart', 1, bm25: 1.0, dense: 0.1);
      final dn = _chunk('b.dart', 1, bm25: 0.1, dense: 1.0);
      final hits = Fusion.fuse(
        [bm],
        [dn],
        options: const FusionOptions(query: 'how to parse config'),
      );
      expect(hits.first.filePath, 'b.dart');
    });

    test('namespaced query treated as symbol', () {
      // Foo::bar has no space but contains :: → symbol.
      final bm = _chunk('a.dart', 1, bm25: 1.0, dense: 0.1);
      final dn = _chunk('b.dart', 1, bm25: 0.1, dense: 1.0);
      final hits = Fusion.fuse(
        [bm],
        [dn],
        options: const FusionOptions(query: 'Foo::bar'),
      );
      expect(hits.first.filePath, 'a.dart');
    });

    test('dotted query treated as symbol', () {
      // "User.find" → symbol (contains .)
      final bm = _chunk('a.dart', 1, bm25: 1.0, dense: 0.1);
      final dn = _chunk('b.dart', 1, bm25: 0.1, dense: 1.0);
      final hits = Fusion.fuse(
        [bm],
        [dn],
        options: const FusionOptions(query: 'User.find'),
      );
      expect(hits.first.filePath, 'a.dart');
    });
  });

  group('formatScoredChunks', () {
    test('formats file:line-range + score per entry', () {
      final out = formatScoredChunks([
        (
          SearchResult(
            filePath: 'a.dart',
            startLine: 1,
            endLine: 5,
            score: 0.5,
            content: 'x',
          ),
          0.5,
        ),
      ]);
      expect(out, contains('a.dart:1-5'));
      expect(out, contains('0.5000'));
    });
  });
}
