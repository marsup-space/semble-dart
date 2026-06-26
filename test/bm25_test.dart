import 'package:semble_dart/src/bm25.dart';
import 'package:test/test.dart';

void main() {
  group('BM25Index constructor', () {
    test('argument validation: k1 must be >= 0', () {
      expect(
        () => BM25Index(documents: const [['a']], k1: -0.1),
        throwsArgumentError,
      );
    });

    test('argument validation: b must be in [0, 1]', () {
      expect(
        () => BM25Index(documents: const [['a']], b: -0.1),
        throwsArgumentError,
      );
      expect(
        () => BM25Index(documents: const [['a']], b: 1.5),
        throwsArgumentError,
      );
    });

    test('empty corpus → zero averages', () {
      final idx = BM25Index(documents: const []);
      expect(idx.numDocs, 0);
      expect(idx.avgDocLength, 0.0);
      expect(idx.query(['anything']), isEmpty);
    });
  });

  group('BM25Index.scoreDoc', () {
    late BM25Index idx;

    setUp(() {
      // Small, predictable corpus:
      //   doc 0: ["parse", "config"]            (2 tokens, all match)
      //   doc 1: ["parse", "json", "config"]    (3 tokens, partial)
      //   doc 2: ["render", "html"]             (2 tokens, no match)
      //   doc 3: ["config", "parser"]           (2 tokens, partial)
      idx = BM25Index(documents: const [
        ['parse', 'config'],
        ['parse', 'json', 'config'],
        ['render', 'html'],
        ['config', 'parser'],
      ]);
    });

    test('doc matching all query terms scores > 0', () {
      final s = idx.scoreDoc(0, ['parse', 'config']);
      expect(s, greaterThan(0));
    });

    test('doc with no matching terms scores 0', () {
      expect(idx.scoreDoc(2, ['parse', 'config']), 0.0);
    });

    test('doc matching one term scores > 0', () {
      expect(idx.scoreDoc(3, ['parse', 'config']), greaterThan(0));
    });

    test('RangeError for out-of-range doc index', () {
      expect(
        () => idx.scoreDoc(-1, ['parse']),
        throwsRangeError,
      );
      expect(
        () => idx.scoreDoc(99, ['parse']),
        throwsRangeError,
      );
    });

    test('repeated query terms count once per term', () {
      // ["parse", "parse", "config"] should give the same score as
      // ["parse", "config"] for any given doc.
      final s = idx.scoreDoc(0, ['parse', 'config']);
      final sDup = idx.scoreDoc(0, ['parse', 'parse', 'parse', 'config']);
      expect(sDup, closeTo(s, 1e-12));
    });

    test('length normalization penalizes longer docs (b=0.75)', () {
      // doc 1 is longer (3 tokens vs 2) and has the same TF for both
      // query terms. With b > 0, doc 1 should score lower per-token.
      final s0 = idx.scoreDoc(0, ['parse', 'config']);
      final s1 = idx.scoreDoc(1, ['parse', 'config']);
      expect(s0, greaterThan(s1));
    });

    test('b=0 disables length normalization', () {
      final flat = BM25Index(documents: const [
        ['parse', 'config'],
        ['parse', 'json', 'config'],
      ], b: 0);
      // Without length normalization, the per-term contributions are
      // identical, so scores are identical too.
      expect(
        flat.scoreDoc(0, ['parse', 'config']),
        closeTo(flat.scoreDoc(1, ['parse', 'config']), 1e-12),
      );
    });

    test('b=1 maximizes length normalization', () {
      final flat = BM25Index(documents: const [
        ['parse', 'config'],
        ['parse', 'json', 'config'],
      ], b: 1);
      // With b=1, doc 1 is even more heavily penalized than default.
      final s0 = flat.scoreDoc(0, ['parse', 'config']);
      final s1 = flat.scoreDoc(1, ['parse', 'config']);
      expect(s0, greaterThan(s1));
      // And the gap widens vs the default-b case:
      final def = BM25Index(documents: const [
        ['parse', 'config'],
        ['parse', 'json', 'config'],
      ]);
      final gap1 = s0 - s1;
      final gap2 = def.scoreDoc(0, ['parse', 'config']) -
          def.scoreDoc(1, ['parse', 'config']);
      expect(gap1, greaterThan(gap2));
    });

    test('k1=0 disables TF saturation (term appears once vs many)', () {
      // In a corpus where "parse" appears 3 times in doc A and 1 time
      // in doc B, with k1=0 the scores should be identical for that
      // term (TF ignored, only IDF contributes).
      final flat = BM25Index(documents: const [
        ['parse', 'parse', 'parse', 'config'],
        ['parse', 'config'],
      ], k1: 0);
      // Both docs have config=1, parse=any; with k1=0, scores equal.
      expect(
        flat.scoreDoc(0, ['parse', 'config']),
        closeTo(flat.scoreDoc(1, ['parse', 'config']), 1e-12),
      );
    });

    test('k1=large amplifies TF differences', () {
      // Same setup as the k1=0 test but with k1 huge: doc with more
      // parse tokens scores higher.
      final flat = BM25Index(documents: const [
        ['parse', 'parse', 'parse', 'config'],
        ['parse', 'config'],
      ], k1: 100);
      expect(
        flat.scoreDoc(0, ['parse']),
        greaterThan(flat.scoreDoc(1, ['parse'])),
      );
    });
  });

  group('BM25Index.query', () {
    late BM25Index idx;

    setUp(() {
      idx = BM25Index(documents: const [
        ['parse', 'config'],
        ['parse', 'json', 'config'],
        ['render', 'html'],
        ['config', 'parser'],
      ]);
    });

    test('returns hits sorted by descending score', () {
      final hits = idx.query(['parse', 'config']);
      expect(hits.length, 3); // docs 0, 1, 3
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i - 1].score, greaterThanOrEqualTo(hits[i].score));
      }
    });

    test('drops docs with score 0', () {
      final hits = idx.query(['parse', 'config']);
      expect(hits.map((h) => h.docIndex), isNot(contains(2)));
    });

    test('topK truncates', () {
      final hits = idx.query(['parse', 'config'], topK: 1);
      expect(hits, hasLength(1));
    });

    test('empty query → empty results', () {
      expect(idx.query([]), isEmpty);
    });

    test('topK < 1 → empty results', () {
      expect(idx.query(['parse'], topK: 0), isEmpty);
    });

    test('hits carry the right doc indices', () {
      final hits = idx.query(['parse', 'config']);
      final docIndices = hits.map((h) => h.docIndex).toSet();
      expect(docIndices, {0, 1, 3});
    });
  });
}