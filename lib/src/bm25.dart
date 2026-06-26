/// BM25Okapi scorer over tokenized documents.
///
/// Documents are lists of string tokens (typically identifier stems
/// from `identifier_stemmer.dart`). Default parameters match the
/// Python `rank_bm25` library: k1 = 1.5, b = 0.75.
///
/// IDF formula uses the Lucene variant (always positive):
///   idf = log(1 + (N - df + 0.5) / (df + 0.5))
///
/// TF with length normalization:
///   tf_norm = f * (k1 + 1) / (f + k1 * (1 - b + b * docLen / avgDocLen))
library;

import 'dart:math' as math;

/// One hit from a BM25 query: a document index and its score.
class BM25Hit {
  final int docIndex;
  final double score;

  const BM25Hit(this.docIndex, this.score);

  @override
  String toString() => 'BM25Hit(doc=$docIndex, score=${score.toStringAsFixed(4)})';
}

/// In-memory BM25 index. Build it once per corpus, query many times.
class BM25Index {
  /// Saturation: how quickly TF saturates. Higher = more weight on TF.
  /// k1 = 0 means TF is ignored entirely (only IDF matters).
  final double k1;

  /// Length normalization: 0 = none, 1 = full (proportional to docLen/avgDocLen).
  final double b;

  /// Number of documents in the index.
  final int numDocs;

  /// Token count per document.
  final List<int> docLengths;

  /// Mean document length (in tokens). Zero if corpus is empty.
  final double avgDocLength;

  /// Document frequency per term: how many docs contain it.
  final Map<String, int> df;

  /// Term frequency per document.
  final List<Map<String, int>> tf;

  BM25Index({
    required List<List<String>> documents,
    this.k1 = 1.5,
    this.b = 0.75,
  })  : numDocs = documents.length,
        docLengths = [for (final d in documents) d.length],
        avgDocLength = documents.isEmpty
            ? 0.0
            : documents.fold<int>(0, (s, d) => s + d.length) /
                documents.length,
        df = _buildDf(documents),
        tf = [for (final d in documents) _buildTf(d)] {
    if (k1 < 0) {
      throw ArgumentError.value(k1, 'k1', 'must be >= 0');
    }
    if (b < 0 || b > 1) {
      throw ArgumentError.value(b, 'b', 'must be in [0, 1]');
    }
  }

  static Map<String, int> _buildDf(List<List<String>> docs) {
    final df = <String, int>{};
    for (final doc in docs) {
      for (final term in doc.toSet()) {
        df.update(term, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    return df;
  }

  static Map<String, int> _buildTf(List<String> doc) {
    final tf = <String, int>{};
    for (final term in doc) {
      tf.update(term, (v) => v + 1, ifAbsent: () => 1);
    }
    return tf;
  }

  /// Score one document against [queryTokens]. Public for tests and
  /// ad-hoc re-ranking; [query] is the common path.
  double scoreDoc(int docIndex, List<String> queryTokens) {
    if (docIndex < 0 || docIndex >= numDocs) {
      throw RangeError(
        'docIndex $docIndex out of range [0, $numDocs)',
      );
    }
    if (avgDocLength == 0 || queryTokens.isEmpty) return 0.0;
    final docLen = docLengths[docIndex];
    final docTf = tf[docIndex];
    double total = 0.0;
    final seen = <String>{};
    for (final term in queryTokens) {
      // De-dupe repeated query terms here (not in [query]) so the
      // caller doesn't pay for it on every doc.
      if (!seen.add(term)) continue;
      final f = docTf[term] ?? 0;
      if (f == 0) continue;
      final dft = df[term] ?? 0;
      if (dft == 0) continue;
      final idf = math.log(1 + (numDocs - dft + 0.5) / (dft + 0.5));
      final tfNorm =
          f * (k1 + 1) / (f + k1 * (1 - b + b * docLen / avgDocLength));
      total += idf * tfNorm;
    }
    return total;
  }

  /// Score all documents, return top-K hits sorted by descending score.
  ///
  /// Documents with score <= 0 are dropped (no match).
  List<BM25Hit> query(List<String> queryTokens, {int topK = 8}) {
    if (numDocs == 0 || topK < 1 || queryTokens.isEmpty) return const [];
    final hits = <BM25Hit>[];
    for (var i = 0; i < numDocs; i++) {
      final s = scoreDoc(i, queryTokens);
      if (s > 0) hits.add(BM25Hit(i, s));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    if (hits.length > topK) return hits.sublist(0, topK);
    return hits;
  }
}