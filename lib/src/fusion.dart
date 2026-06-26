/// Reciprocal Rank Fusion + 5 code-aware rerank signals.
///
/// Fuses two ranked candidate lists (BM25 lexical + dense embedding)
/// into a single list via RRF, then applies the upstream Semble rerank
/// signals:
///
///   1. **Adaptive weighting**: symbol-like queries (single identifier
///      or `Foo::bar` / `User.find`) get extra weight on BM25 matches;
///      natural-language queries get extra weight on dense matches.
///   2. **Definition boost**: chunks that *define* a symbol (class /
///      function / method) are boosted over chunks that only *use* it.
///   3. **Identifier stems**: query tokens matched against precomputed
///      identifier stems in the chunk give an additive bonus.
///   4. **File coherence**: when several chunks from the same file
///      surface, the file gets a multiplicative boost (top result
///      reflects broad file relevance, not a single lucky snippet).
///   5. **Noise penalty**: test files, `compat/` / `legacy/` shims,
///      `.d.ts` stubs, and example code are down-ranked.
///
/// The output is a deduplicated list of [SearchResult] (the wire type
/// Crux's tool layer already consumes) sorted by final score.
library;

import 'protocol.dart' show SearchResult;

/// A single chunk with both retriever scores + metadata for rerank.
class RankedChunk {
  final SearchResult chunk;
  final double bm25Score;
  final double denseScore;
  final bool isDefinition;

  /// Precomputed identifier stems (from `identifier_stemmer.dart`).
  /// Empty list = no stems, stem-signal is skipped for this chunk.
  final List<String> stems;

  /// Convenience: the chunk's file path. Equivalent to `chunk.filePath`
  /// but exposed as a top-level field so the [Fusion] API doesn't have
  /// to reach into the [SearchResult] internals at every callsite.
  String get filePath => chunk.filePath;

  const RankedChunk({
    required this.chunk,
    this.bm25Score = 0.0,
    this.denseScore = 0.0,
    this.isDefinition = false,
    this.stems = const [],
  });
}

/// Tuning knobs for [Fusion.fuse].
class FusionOptions {
  /// RRF constant: `score = sum(1 / (k + rank))`. k = 60 is the
  /// standard value from the original RRF paper.
  final int rrfK;

  /// Top-K results to return.
  final int topK;

  /// Original query string, used for symbol-like detection.
  final String? query;

  /// Pre-stemmed query tokens for the identifier-stems signal.
  /// If null, the stem signal is skipped (callers can pass an empty
  /// list to disable without code changes).
  final List<String>? queryStems;

  const FusionOptions({
    this.rrfK = 60,
    this.topK = 8,
    this.query,
    this.queryStems,
  });
}

/// Pure-function RRF + rerank. Stateless — every call is independent.
class Fusion {
  /// Combine BM25 + dense hits and return top-K [SearchResult]s.
  static List<SearchResult> fuse(
    List<RankedChunk> bm25Hits,
    List<RankedChunk> denseHits, {
    FusionOptions options = const FusionOptions(),
  }) {
    if (options.topK < 1) return const [];

    // 1. Deduplicate by location. If a chunk appears in both lists,
    //    keep one with the highest combined raw score so its rerank
    //    metadata is representative.
    final byKey = <String, RankedChunk>{};
    _absorb(byKey, bm25Hits);
    _absorb(byKey, denseHits);

    if (byKey.isEmpty) return const [];

    // 2. RRF score per unique location.
    final rrf = <String, double>{};
    _addRrf(rrf, bm25Hits, options.rrfK);
    _addRrf(rrf, denseHits, options.rrfK);

    // 3. File coherence: count how many candidates each file contributes.
    final fileCounts = <String, int>{};
    for (final c in byKey.values) {
      fileCounts.update(
        c.filePath,
        (v) => v + 1,
        ifAbsent: () => 1,
      );
    }

    // 4. Apply rerank signals.
    final isSymbol = _isSymbolQuery(options.query);
    final queryStems = options.queryStems;
    final queryStemSet = queryStems?.toSet();

    final scored = <(String, double)>[];
    for (final entry in byKey.entries) {
      final key = entry.key;
      final chunk = entry.value;
      var score = rrf[key] ?? 0.0;
      final total = chunk.bm25Score + chunk.denseScore;

      // 4a. Adaptive weighting.
      if (total > 0) {
        if (isSymbol && chunk.bm25Score > 0) {
          score *= 1.0 + 0.3 * (chunk.bm25Score / total);
        } else if (!isSymbol && chunk.denseScore > 0) {
          score *= 1.0 + 0.2 * (chunk.denseScore / total);
        }
      }

      // 4b. Definition boost.
      if (chunk.isDefinition) {
        score *= 1.2;
      }

      // 4c. Identifier stems overlap.
      if (queryStemSet != null && queryStemSet.isNotEmpty &&
          chunk.stems.isNotEmpty) {
        final overlap =
            queryStemSet.intersection(chunk.stems.toSet()).length;
        if (overlap > 0) {
          score *= 1.0 + 0.1 * overlap;
        }
      }

      // 4d. File coherence.
      final fileCount = fileCounts[chunk.filePath] ?? 1;
      if (fileCount > 1) {
        score *= 1.0 + 0.05 * (fileCount - 1);
      }

      // 4e. Noise penalty.
      if (_isNoiseFile(chunk.filePath)) {
        score *= 0.85;
      }

      scored.add((key, score));
    }

    // 5. Sort by final score, drop ties by stable chunk order.
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
    });

    final top = scored.take(options.topK).map((e) => byKey[e.$1]!.chunk);
    return top.toList();
  }

  /// Absorb a hit list into the dedup map. If two hits have the same
  /// location, the one with higher combined raw score wins (its
  /// metadata — `isDefinition`, `stems` — is more likely to be the
  /// canonical entry).
  static void _absorb(Map<String, RankedChunk> into, List<RankedChunk> hits) {
    for (final h in hits) {
      final key = _key(h);
      final existing = into[key];
      if (existing == null) {
        into[key] = h;
        continue;
      }
      final newTotal = h.bm25Score + h.denseScore;
      final oldTotal = existing.bm25Score + existing.denseScore;
      if (newTotal > oldTotal) into[key] = h;
    }
  }

  static void _addRrf(
    Map<String, double> rrf,
    List<RankedChunk> hits,
    int k,
  ) {
    for (var i = 0; i < hits.length; i++) {
      final key = _key(hits[i]);
      final contrib = 1.0 / (k + i + 1);
      rrf.update(key, (v) => v + contrib, ifAbsent: () => contrib);
    }
  }

  static String _key(RankedChunk c) => '${c.filePath}:${c.chunk.startLine}';

  /// Symbol-like query = single token (no whitespace) OR contains
  /// `::` / `.` separator (namespaces / method calls).
  static bool _isSymbolQuery(String? query) {
    if (query == null || query.isEmpty) return false;
    return !query.contains(' ') || query.contains('::') || query.contains('.');
  }

  /// Detect test files, compatibility shims, and declaration stubs.
  static bool _isNoiseFile(String path) {
    final lower = path.toLowerCase();
    return lower.contains('/test/') ||
        lower.contains('/tests/') ||
        lower.contains('/__tests__/') ||
        lower.endsWith('_test.dart') ||
        lower.endsWith('_test.py') ||
        lower.endsWith('_test.go') ||
        lower.endsWith('.test.ts') ||
        lower.endsWith('.test.js') ||
        lower.endsWith('.spec.ts') ||
        lower.endsWith('.spec.js') ||
        lower.endsWith('.d.ts') ||
        lower.contains('/compat/') ||
        lower.contains('/legacy/') ||
        lower.contains('/examples/') ||
        lower.contains('/example/');
  }
}

/// Diagnostic: pretty-print a scored chunk list for logging.
String formatScoredChunks(List<(SearchResult, double)> scored) {
  final buf = StringBuffer();
  for (final (chunk, score) in scored) {
    buf.writeln(
      '${chunk.filePath}:${chunk.startLine}-${chunk.endLine} '
      'score=${score.toStringAsFixed(4)}',
    );
  }
  return buf.toString();
}