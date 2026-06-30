import 'dart:typed_data';

import 'bm25.dart';
import 'cache.dart';
import 'chunker.dart';
import 'file_walker.dart';
import 'fusion.dart';
import 'identifier_stemmer.dart';
import 'model.dart';
import 'protocol.dart';
import 'tokenizer.dart';
import 'treesitter/parser.dart';

class SembleIndex {
  final List<CodeChunk> chunks;
  final List<List<String>> stems;
  final List<Float32List>? embeddings;
  final BM25Index bm25;
  final EmbeddingModel? model;
  final WordPieceTokenizer? tokenizer;

  SembleIndex._({
    required this.chunks,
    required this.stems,
    required this.bm25,
    required this.embeddings,
    required this.model,
    required this.tokenizer,
  });

  static Future<SembleIndex> fromPath({
    required String rootPath,
    required TreeSitterParser parser,
    required AstChunker chunker,
    SembleCache? cache,
    EmbeddingModel? model,
    WordPieceTokenizer? tokenizer,
  }) async {
    if ((model == null) != (tokenizer == null)) {
      throw ArgumentError('model and tokenizer must be provided together');
    }

    final walker = await SembleFileWalker.create(rootPath);
    final paths = await walker.collectCodeFiles();
    final chunks = <CodeChunk>[];

    for (final path in paths) {
      final cached = await cache?.readChunks(path);
      if (cached != null) {
        chunks.addAll(cached);
        continue;
      }

      final parsed = await parser.parseFile(path);
      try {
        final parsedChunks = chunker.chunk(parsed);
        chunks.addAll(parsedChunks);
        await cache?.writeChunks(path, parsedChunks);
      } finally {
        parsed.close();
      }
    }

    return SembleIndex.fromChunks(chunks, model: model, tokenizer: tokenizer);
  }

  factory SembleIndex.fromChunks(
    List<CodeChunk> chunks, {
    EmbeddingModel? model,
    WordPieceTokenizer? tokenizer,
  }) {
    if ((model == null) != (tokenizer == null)) {
      throw ArgumentError('model and tokenizer must be provided together');
    }
    final stemmer = const IdentifierStemmer();
    final stems = [for (final chunk in chunks) stemmer.stems(chunk.content)];
    final embeddings = model == null || tokenizer == null
        ? null
        : [
            for (final chunk in chunks)
              model.encode(tokenizer.tokenize(chunk.content)),
          ];
    return SembleIndex._(
      chunks: List.unmodifiable(chunks),
      stems: List.unmodifiable(stems),
      bm25: BM25Index(documents: stems),
      embeddings: embeddings == null ? null : List.unmodifiable(embeddings),
      model: model,
      tokenizer: tokenizer,
    );
  }

  List<SearchResult> search(String query, {int topK = 8}) {
    if (topK < 1 || query.trim().isEmpty || chunks.isEmpty) return const [];

    final stemmer = const IdentifierStemmer();
    final queryStems = stemmer.stems(query);
    final bm25Hits = [
      for (final hit in bm25.query(queryStems, topK: topK * 4))
        _rankedChunk(hit.docIndex, bm25Score: hit.score),
    ];

    final denseHits = _denseSearch(query, topK: topK * 4);
    return Fusion.fuse(
      bm25Hits,
      denseHits,
      options: FusionOptions(topK: topK, query: query, queryStems: queryStems),
    );
  }

  List<SearchResult> findRelated({
    required String file,
    required int line,
    int topK = 8,
  }) {
    if (topK < 1 || chunks.isEmpty) return const [];
    final anchorIndex = chunks.indexWhere(
      (chunk) =>
          chunk.filePath == file &&
          chunk.startLine <= line &&
          chunk.endLine >= line,
    );
    if (anchorIndex < 0) return const [];

    final anchor = chunks[anchorIndex];
    final bm25Hits = [
      for (final hit in bm25.query(stems[anchorIndex], topK: topK * 4 + 1))
        if (hit.docIndex != anchorIndex)
          _rankedChunk(hit.docIndex, bm25Score: hit.score),
    ];

    final denseHits = _denseRelated(anchorIndex, topK: topK * 4 + 1);
    return Fusion.fuse(
      bm25Hits,
      denseHits,
      options: FusionOptions(
        topK: topK,
        query: anchor.content,
        queryStems: stems[anchorIndex],
      ),
    );
  }

  List<RankedChunk> _denseSearch(String query, {required int topK}) {
    final localModel = model;
    final localTokenizer = tokenizer;
    final localEmbeddings = embeddings;
    if (localModel == null ||
        localTokenizer == null ||
        localEmbeddings == null) {
      return const [];
    }
    final queryVector = localModel.encode(localTokenizer.tokenize(query));
    return _denseNearest(queryVector, topK: topK);
  }

  List<RankedChunk> _denseRelated(int anchorIndex, {required int topK}) {
    final localEmbeddings = embeddings;
    if (localEmbeddings == null) return const [];
    return _denseNearest(
      localEmbeddings[anchorIndex],
      topK: topK,
      excludeIndex: anchorIndex,
    );
  }

  List<RankedChunk> _denseNearest(
    Float32List queryVector, {
    required int topK,
    int? excludeIndex,
  }) {
    final localEmbeddings = embeddings;
    if (localEmbeddings == null || topK < 1) return const [];

    final scored = <(int, double)>[];
    for (var i = 0; i < localEmbeddings.length; i++) {
      if (i == excludeIndex) continue;
      final score = EmbeddingModel.cosineSimilarity(
        queryVector,
        localEmbeddings[i],
      );
      if (score > 0) scored.add((i, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final (index, score) in scored.take(topK))
        _rankedChunk(index, denseScore: score),
    ];
  }

  RankedChunk _rankedChunk(
    int index, {
    double bm25Score = 0.0,
    double denseScore = 0.0,
  }) {
    final chunk = chunks[index];
    return RankedChunk(
      chunk: SearchResult(
        filePath: chunk.filePath,
        startLine: chunk.startLine,
        endLine: chunk.endLine,
        score: bm25Score + denseScore,
        content: chunk.content,
      ),
      bm25Score: bm25Score,
      denseScore: denseScore,
      isDefinition: chunk.isDefinition,
      stems: stems[index],
    );
  }
}
