/// Reciprocal Rank Fusion + upstream Semble code-aware rerank signals.
///
/// Fuses two ranked candidate lists (BM25 lexical + dense embedding)
/// into a single list via RRF, then applies the upstream Semble rerank
/// signals:
///
///   1. **Alpha-weighted RRF**: symbol-like queries use more BM25
///      weight; natural-language queries use a balanced lexical/dense mix.
///   2. **File coherence**: a file with multiple relevant chunks gets an
///      additive boost on its top candidate.
///   3. **Query boosts**: symbol queries promote matching definitions;
///      natural-language queries promote matching file/parent stems and
///      embedded CamelCase symbol definitions.
///   4. **Path penalties**: test files, `compat/` / `legacy/` shims,
///      `.d.ts` stubs, and example code are down-ranked.
///   5. **File saturation**: repeated chunks from the same file decay
///      after the first selected result.
///
/// The output is a deduplicated list of [SearchResult] (the wire type
/// Crux's tool layer already consumes) sorted by final score.
library;

import 'dart:math' as math;

import 'identifier_stemmer.dart';
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

  /// Pre-stemmed query tokens retained for callers that already compute
  /// them; upstream-style fusion currently derives query boosts from the
  /// raw query string and file paths.
  final List<String>? queryStems;

  /// All chunks in the searched scope. Used by upstream-style query boosts
  /// that may promote symbol definitions not returned by either retriever.
  final List<RankedChunk>? allChunks;

  /// Semantic blend weight. `null` matches upstream auto-detection.
  final double? alpha;

  /// Whether to apply rerank boosts/penalties.
  final bool rerank;

  const FusionOptions({
    this.rrfK = 60,
    this.topK = 8,
    this.query,
    this.queryStems,
    this.allChunks,
    this.alpha,
    this.rerank = true,
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

    final semanticRrf = <String, double>{};
    final bm25Rrf = <String, double>{};
    _addRrf(bm25Rrf, bm25Hits, options.rrfK);
    _addRrf(semanticRrf, denseHits, options.rrfK);

    final alpha = _resolveAlpha(options.query, options.alpha);
    final keys = {...semanticRrf.keys, ...bm25Rrf.keys}.toList()
      ..sort((a, b) {
        final aLine = byKey[a]?.chunk.startLine ?? 0;
        final bLine = byKey[b]?.chunk.startLine ?? 0;
        return aLine.compareTo(bLine);
      });

    final scores = <String, double>{
      for (final key in keys)
        key:
            alpha * (semanticRrf[key] ?? 0.0) +
            (1.0 - alpha) * (bm25Rrf[key] ?? 0.0),
    };

    if (!options.rerank) {
      return _topResults(scores, byKey, options.topK);
    }

    _boostMultiChunkFiles(scores, byKey);
    _applyQueryBoost(scores, byKey, options);
    return _rerankTopK(scores, byKey, options.topK, penalisePaths: alpha < 1.0);
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

  static void _addRrf(Map<String, double> rrf, List<RankedChunk> hits, int k) {
    for (var i = 0; i < hits.length; i++) {
      final key = _key(hits[i]);
      final contrib = 1.0 / (k + i + 1);
      rrf.update(key, (v) => v + contrib, ifAbsent: () => contrib);
    }
  }

  static String _key(RankedChunk c) => '${c.filePath}:${c.chunk.startLine}';

  static List<SearchResult> _topResults(
    Map<String, double> scores,
    Map<String, RankedChunk> byKey,
    int topK,
  ) {
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final entry in ranked.take(topK))
        _withScore(byKey[entry.key]!, entry.value),
    ];
  }

  static SearchResult _withScore(RankedChunk chunk, double score) {
    final r = chunk.chunk;
    return SearchResult(
      filePath: r.filePath,
      startLine: r.startLine,
      endLine: r.endLine,
      score: score,
      content: r.content,
    );
  }

  static double _resolveAlpha(String? query, double? alpha) {
    if (alpha != null) return alpha;
    return _isSymbolQuery(query) ? 0.3 : 0.5;
  }

  /// Mirrors upstream `is_symbol_query`.
  static bool _isSymbolQuery(String? query) {
    if (query == null || query.isEmpty) return false;
    return RegExp(
      r'^(?:[A-Za-z_][A-Za-z0-9_]*(?:(?:::|\\|->|\.)[A-Za-z_][A-Za-z0-9_]*)+|_[A-Za-z0-9_]*|[A-Za-z][A-Za-z0-9]*[A-Z_][A-Za-z0-9_]*|[A-Z][A-Za-z0-9]*)$',
    ).hasMatch(query.trim());
  }

  static void _boostMultiChunkFiles(
    Map<String, double> scores,
    Map<String, RankedChunk> byKey,
  ) {
    if (scores.isEmpty) return;
    final maxScore = scores.values.reduce(math.max);
    if (maxScore == 0.0) return;

    final fileSum = <String, double>{};
    final bestKey = <String, String>{};
    for (final entry in scores.entries) {
      final chunk = byKey[entry.key]!;
      fileSum.update(
        chunk.filePath,
        (v) => v + entry.value,
        ifAbsent: () => entry.value,
      );
      final currentBest = bestKey[chunk.filePath];
      if (currentBest == null || entry.value > (scores[currentBest] ?? 0.0)) {
        bestKey[chunk.filePath] = entry.key;
      }
    }

    final maxFileSum = fileSum.values.reduce(math.max);
    final boostUnit = maxScore * 0.2;
    for (final entry in bestKey.entries) {
      scores[entry.value] =
          (scores[entry.value] ?? 0.0) +
          boostUnit * (fileSum[entry.key] ?? 0.0) / maxFileSum;
    }
  }

  static void _applyQueryBoost(
    Map<String, double> scores,
    Map<String, RankedChunk> byKey,
    FusionOptions options,
  ) {
    if (scores.isEmpty) return;
    final query = options.query;
    if (query == null || query.trim().isEmpty) return;
    final maxScore = scores.values.reduce(math.max);

    if (_isSymbolQuery(query)) {
      _boostSymbolDefinitions(
        scores,
        byKey,
        query,
        maxScore,
        options.allChunks,
      );
    } else {
      _boostStemMatches(scores, byKey, query, maxScore);
      _boostEmbeddedSymbols(scores, byKey, query, maxScore, options.allChunks);
    }
  }

  static void _boostSymbolDefinitions(
    Map<String, double> scores,
    Map<String, RankedChunk> byKey,
    String query,
    double maxScore,
    List<RankedChunk>? allChunks,
  ) {
    final symbolName = _extractSymbolName(query);
    final names = <String>{symbolName};
    if (symbolName != query.trim()) names.add(query.trim());
    final boostUnit = maxScore * 3.0;

    for (final key in scores.keys.toList()) {
      final tier = _definitionTier(byKey[key]!, names, boostUnit);
      if (tier > 0) scores[key] = (scores[key] ?? 0.0) + tier;
    }

    _scanNonCandidates(
      scores,
      byKey,
      allChunks,
      names,
      boostUnit,
      (stem) => _stemMatches(stem, symbolName.toLowerCase()),
    );
  }

  static void _boostEmbeddedSymbols(
    Map<String, double> scores,
    Map<String, RankedChunk> byKey,
    String query,
    double maxScore,
    List<RankedChunk>? allChunks,
  ) {
    final names = RegExp(
      r'\b(?:[A-Z][a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*|[a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]+)\b',
    ).allMatches(query).map((m) => m.group(0)!).toSet();
    if (names.isEmpty) return;

    final boostUnit = maxScore * 3.0 * 0.5;
    for (final key in scores.keys.toList()) {
      final tier = _definitionTier(byKey[key]!, names, boostUnit);
      if (tier > 0) scores[key] = (scores[key] ?? 0.0) + tier;
    }

    final lowered = names.map((s) => s.toLowerCase()).toSet();
    _scanNonCandidates(scores, byKey, allChunks, names, boostUnit, (stem) {
      final stemNorm = stem.replaceAll('_', '');
      return lowered.any(
        (symbol) =>
            stem == symbol ||
            stemNorm == symbol ||
            (stem.length >= 4 && symbol.startsWith(stem)) ||
            (stemNorm.length >= 4 && symbol.startsWith(stemNorm)),
      );
    });
  }

  static void _scanNonCandidates(
    Map<String, double> scores,
    Map<String, RankedChunk> byKey,
    List<RankedChunk>? allChunks,
    Set<String> names,
    double boostUnit,
    bool Function(String stem) stemOk,
  ) {
    if (allChunks == null) return;
    for (final chunk in allChunks) {
      final key = _key(chunk);
      if (scores.containsKey(key)) continue;
      if (!stemOk(_pathStem(chunk.filePath).toLowerCase())) continue;
      final tier = _definitionTier(chunk, names, boostUnit);
      if (tier > 0) {
        byKey[key] = chunk;
        scores[key] = tier;
      }
    }
  }

  static String _extractSymbolName(String query) {
    final trimmed = query.trim();
    for (final separator in ['::', r'\', '->', '.']) {
      if (trimmed.contains(separator)) return trimmed.split(separator).last;
    }
    return trimmed;
  }

  static double _definitionTier(
    RankedChunk chunk,
    Set<String> names,
    double boostUnit,
  ) {
    if (!names.any((name) => _chunkDefinesSymbol(chunk.chunk.content, name))) {
      return 0.0;
    }
    final stem = _pathStem(chunk.filePath).toLowerCase();
    return boostUnit *
        (names.any((name) => _stemMatches(stem, name.toLowerCase()))
            ? 1.5
            : 1.0);
  }

  static bool _chunkDefinesSymbol(String content, String symbolName) {
    final escaped = RegExp.escape(symbolName);
    final nsPrefix = r'(?:[A-Za-z_][A-Za-z0-9_]*(?:\.|::))*';
    final general = RegExp(
      r'(?:^|(?<=\s))(?:class|module|defmodule|def|interface|struct|enum|trait|type|func|function|object|abstract class|data class|fn|fun|package|namespace|protocol|record|typedef)\s+' +
          nsPrefix +
          escaped +
          r'(?:\s|[<({:\[;]|$)',
      multiLine: true,
    );
    final sql = RegExp(
      r'(?:^|(?<=\s))(?:CREATE TABLE|CREATE VIEW|CREATE PROCEDURE|CREATE FUNCTION)\s+' +
          nsPrefix +
          escaped +
          r'(?:\s|[<({:\[;]|$)',
      multiLine: true,
      caseSensitive: false,
    );
    return general.hasMatch(content) || sql.hasMatch(content);
  }

  static bool _stemMatches(String stem, String name) {
    final stemNorm = stem.replaceAll('_', '');
    return stem == name ||
        stemNorm == name ||
        _rstripS(stem) == name ||
        _rstripS(stemNorm) == name;
  }

  static String _rstripS(String value) {
    var end = value.length;
    while (end > 0 && value.codeUnitAt(end - 1) == 0x73) {
      end--;
    }
    return value.substring(0, end);
  }

  static void _boostStemMatches(
    Map<String, double> scores,
    Map<String, RankedChunk> byKey,
    String query,
    double maxScore,
  ) {
    const stopwords = {
      'a',
      'an',
      'and',
      'are',
      'as',
      'at',
      'be',
      'by',
      'do',
      'does',
      'for',
      'from',
      'has',
      'have',
      'how',
      'if',
      'in',
      'is',
      'it',
      'not',
      'of',
      'on',
      'or',
      'the',
      'to',
      'was',
      'what',
      'when',
      'where',
      'which',
      'who',
      'why',
      'with',
    };
    final keywords = RegExp(r'[a-zA-Z_][a-zA-Z0-9_]*')
        .allMatches(query)
        .map((m) => m.group(0)!.toLowerCase())
        .where((word) => word.length > 2 && !stopwords.contains(word))
        .toSet();
    if (keywords.isEmpty) return;

    final stemmer = const IdentifierStemmer();
    final boost = maxScore;
    final pathCache = <String, Set<String>>{};
    for (final key in scores.keys.toList()) {
      final chunk = byKey[key]!;
      final parts = pathCache.putIfAbsent(chunk.filePath, () {
        final parts = <String>{...stemmer.stems(_pathStem(chunk.filePath))};
        final parent = _parentName(chunk.filePath);
        if (parent.isNotEmpty && parent != '.' && parent != '..') {
          parts.addAll(stemmer.stems(parent));
        }
        return parts;
      });
      final matches = _countKeywordMatches(keywords, parts);
      if (matches > 0) {
        final ratio = matches / keywords.length;
        if (ratio >= 0.10) scores[key] = (scores[key] ?? 0.0) + boost * ratio;
      }
    }
  }

  static int _countKeywordMatches(Set<String> keywords, Set<String> parts) {
    var count = keywords.intersection(parts).length;
    for (final keyword in keywords.difference(parts)) {
      for (final part in parts) {
        final shorter = keyword.length <= part.length ? keyword : part;
        final longer = keyword.length <= part.length ? part : keyword;
        if (shorter.length >= 3 && longer.startsWith(shorter)) {
          count++;
          break;
        }
      }
    }
    return count;
  }

  static List<SearchResult> _rerankTopK(
    Map<String, double> scores,
    Map<String, RankedChunk> byKey,
    int topK, {
    required bool penalisePaths,
  }) {
    if (scores.isEmpty) return const [];
    final penalised = <String, double>{};
    final penaltyCache = <String, double>{};
    for (final entry in scores.entries) {
      final chunk = byKey[entry.key]!;
      final penalty = penalisePaths
          ? penaltyCache.putIfAbsent(
              chunk.filePath,
              () => _filePathPenalty(chunk.filePath),
            )
          : 1.0;
      penalised[entry.key] = entry.value * penalty;
    }

    final ranked = penalised.keys.toList()
      ..sort((a, b) => (penalised[b] ?? 0.0).compareTo(penalised[a] ?? 0.0));

    final fileSelected = <String, int>{};
    final selected = <(double, String)>[];
    var minSelected = double.infinity;
    for (final key in ranked) {
      final chunk = byKey[key]!;
      final penScore = penalised[key] ?? 0.0;
      if (selected.length >= topK && penScore <= minSelected) break;

      final alreadySelected = fileSelected[chunk.filePath] ?? 0;
      var effective = penScore;
      if (alreadySelected >= 1) {
        final excess = alreadySelected;
        effective *= math.pow(0.5, excess).toDouble();
      }
      selected.add((effective, key));
      fileSelected[chunk.filePath] = alreadySelected + 1;
      if (selected.length >= topK) {
        minSelected = selected.map((e) => e.$1).reduce(math.min);
      }
    }

    selected.sort((a, b) => b.$1.compareTo(a.$1));
    return [
      for (final entry in selected.take(topK))
        _withScore(byKey[entry.$2]!, entry.$1),
    ];
  }

  static double _filePathPenalty(String filePath) {
    final normalised = filePath.replaceAll(r'\', '/');
    var penalty = 1.0;
    if (_testFileRe.hasMatch(normalised) || _testDirRe.hasMatch(normalised)) {
      penalty *= 0.3;
    }
    if (_reexportFilenames.contains(_baseName(filePath))) {
      penalty *= 0.5;
    }
    if (_compatDirRe.hasMatch(normalised)) penalty *= 0.3;
    if (_examplesDirRe.hasMatch(normalised)) penalty *= 0.3;
    if (normalised.endsWith('.d.ts')) penalty *= 0.7;
    return penalty;
  }
}

final _testFileRe = RegExp(
  r'(?:^|/)(?:test_[^/]*\.py|[^/]*_test\.py|[^/]*_test\.go|[^/]*Tests?\.java|[^/]*Test\.php|[^/]*_spec\.rb|[^/]*_test\.rb|[^/]*\.test\.[jt]sx?|[^/]*\.spec\.[jt]sx?|[^/]*Tests?\.kt|[^/]*Spec\.kt|[^/]*Tests?\.swift|[^/]*Spec\.swift|[^/]*Tests?\.cs|test_[^/]*\.cpp|[^/]*_test\.cpp|test_[^/]*\.c|[^/]*_test\.c|[^/]*Spec\.scala|[^/]*Suite\.scala|[^/]*Test\.scala|[^/]*_test\.dart|test_[^/]*\.dart|[^/]*_spec\.lua|[^/]*_test\.lua|test_[^/]*\.lua|test_helpers?[^/]*\.\w+)$',
);
final _testDirRe = RegExp(r'(?:^|/)(?:tests?|__tests__|spec|testing)(?:/|$)');
final _compatDirRe = RegExp(r'(?:^|/)(?:compat|_compat|legacy)(?:/|$)');
final _examplesDirRe = RegExp(r'(?:^|/)(?:_?examples?|docs?_src)(?:/|$)');
const _reexportFilenames = {'__init__.py', 'package-info.java'};

String _baseName(String path) => path.replaceAll(r'\', '/').split('/').last;

String _pathStem(String path) {
  final base = _baseName(path);
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}

String _parentName(String path) {
  final parts = path.replaceAll(r'\', '/').split('/');
  return parts.length < 2 ? '' : parts[parts.length - 2];
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
