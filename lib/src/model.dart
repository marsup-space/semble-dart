/// Static embedding model — `potion-code-16M` (Model2Vec).
///
/// Loaded from a HuggingFace `model.safetensors` file. Stores a single
/// tensor: a `[vocabSize, dim]` F32 matrix where `vocabSize` is the
/// tokenizer's vocab size (~62.5K for Potion) and `dim = 256`.
///
/// Encoding: given a list of token IDs, look up the rows, mean-pool
/// across the tokens, L2-normalize. That's the whole forward pass —
/// Model2Vec is "static" because there is no transformer at query
/// time, so encoding is a single matrix-multiply-shaped operation.
///
/// The safetensors format reference: https://huggingface.co/docs/safetensors/index
///   bytes 0..7     : uint64 LE header length
///   bytes 8..N     : UTF-8 JSON header (no padding, exactly N bytes)
///   bytes N..      : tensor data, in the order listed in the header
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class EmbeddingModel {
  /// Row-major `[vocabSize, dim]` F32 weight matrix.
  final Float32List weights;
  final int vocabSize;
  final int dim;

  /// Optional `[vocabSize]` I64 token ID remap. model2vec files
  /// ship a `mapping` tensor so that the model can keep its
  /// internal embedding table compact while still exposing a
  /// stable external vocabulary; the remap converts a token's
  /// external ID to the internal row in [weights]. `null` for
  /// non-model2vec safetensors (where the embedding table IS the
  /// external vocabulary, indexed 1:1 by token ID).
  final Int32List? mapping;

  /// Optional `[vocabSize]` F64 per-token SIF (Smooth Inverse
  /// Frequency) weight. model2vec's `encode` multiplies each
  /// token's embedding row by this weight before mean-pooling, so
  /// high-frequency tokens (e.g. `def`, `class`, `import`) get
  /// down-weighted and rare tokens (identifiers, domain terms)
  /// dominate the sentence vector. `null` if the safetensors
  /// didn't ship a `weights` tensor.
  ///
  /// We store the F64 values as-is and downcast to F32 at the
  /// multiply site (numpy auto-promotes and the precision loss
  /// is below the F32 embedding precision).
  final Float64List? sifWeights;

  const EmbeddingModel._({
    required this.weights,
    required this.vocabSize,
    required this.dim,
    this.mapping,
    this.sifWeights,
  });

  /// Load from a safetensors file on disk.
  static Future<EmbeddingModel> fromFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return EmbeddingModel.fromBytes(bytes);
  }

  /// Load from an in-memory safetensors byte buffer. Used by tests
  /// with synthetic small payloads.
  factory EmbeddingModel.fromBytes(Uint8List bytes) {
    if (bytes.length < 8) {
      throw ArgumentError('safetensors buffer too short for header length');
    }
    final headerLength =
        ByteData.sublistView(bytes, 0, 8).getUint64(0, Endian.little);

    if (bytes.length < 8 + headerLength) {
      throw ArgumentError(
        'safetensors buffer too short for header '
        '(have ${bytes.length}, need ${8 + headerLength})',
      );
    }
    final headerBytes = bytes.sublist(8, 8 + headerLength);
    final headerJson =
        jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;

    // Find the embedding tensor. model2vec-format files (like
    // potion-code-16M) ship 3 tensors: `mapping` (I64, token ID
    // remap), `weights` (F64, per-token SIF weights), and
    // `embeddings` (F32, the matrix). We use `apply_sif=True` to
    // match upstream model2vec default (multiply per-token
    // embedding by SIF weight before mean-pool) — this is what
    // gives the dense retriever its code-aware signal and is
    // critical for top-5 path overlap with the Python reference.
    Map<String, dynamic>? tensorMeta;
    String? tensorName;
    for (final entry in headerJson.entries) {
      if (entry.key == '__metadata__') continue;
      final meta = entry.value as Map<String, dynamic>;
      if (entry.key == 'embeddings') {
        tensorName = entry.key;
        tensorMeta = meta;
        break;
      }
      // First-F32-2D fallback for arbitrary safetensors files.
      if (tensorMeta == null &&
          meta['dtype'] == 'F32' &&
          (meta['shape'] as List).length == 2) {
        tensorName = entry.key;
        tensorMeta = meta;
      }
    }
    if (tensorMeta == null || tensorName == null) {
      throw ArgumentError(
        'safetensors file has no F32 2D tensor (and no '
        '"embeddings" entry)',
      );
    }

    final dtype = tensorMeta['dtype'] as String?;
    if (dtype != 'F32') {
      throw ArgumentError('expected F32 tensor, got "$dtype"');
    }

    final shape = (tensorMeta['shape'] as List).cast<num>();
    if (shape.length != 2) {
      throw ArgumentError('expected 2D tensor, got ${shape.length}D');
    }
    final vocabSize = shape[0].toInt();
    final dim = shape[1].toInt();

    final offsets = (tensorMeta['data_offsets'] as List).cast<num>();
    final start = offsets[0].toInt();
    final end = offsets[1].toInt();
    final expectedBytes = vocabSize * dim * 4;
    if (end - start != expectedBytes) {
      throw ArgumentError(
        'tensor byte count $expectedBytes != data range ${end - start}',
      );
    }

    final dataStart = 8 + headerLength + start;
    final dataEnd = 8 + headerLength + end;
    if (bytes.length < dataEnd) {
      throw ArgumentError('safetensors buffer truncated');
    }

    // View the tensor's bytes as a Float32List, then copy out so the
    // result is independent of the input bytes (which might be reused).
    final tensorBytes = bytes.sublist(dataStart, dataEnd);
    final view = tensorBytes.buffer.asFloat32List(
      tensorBytes.offsetInBytes,
      vocabSize * dim,
    );
    final weights = Float32List.fromList(view);

    // Optional model2vec auxiliary tensors: `mapping` (I64 token
    // remap) and `weights` (F64 SIF weight). Both are 1D of length
    // [vocabSize]. Reading them is best-effort — non-model2vec
    // safetensors won't have these and we just skip SIF.
    Int32List? mapping;
    Float64List? sifWeights;
    final mappingMeta = headerJson['mapping'];
    if (mappingMeta is Map<String, dynamic>) {
      mapping = _readI64Vector1D(bytes, headerLength, mappingMeta, vocabSize);
    }
    final sifMeta = headerJson['weights'];
    if (sifMeta is Map<String, dynamic>) {
      sifWeights = _readF64Vector1D(bytes, headerLength, sifMeta, vocabSize);
    }

    return EmbeddingModel._(
      weights: weights,
      vocabSize: vocabSize,
      dim: dim,
      mapping: mapping,
      sifWeights: sifWeights,
    );
  }

  /// Read a 1D I64 tensor of the expected length from a safetensors
  /// byte buffer. Returns null on any header inconsistency so the
  /// caller can degrade gracefully when the tensor is absent or
  /// the wrong shape.
  static Int32List? _readI64Vector1D(
    Uint8List bytes,
    int headerLength,
    Map<String, dynamic> meta,
    int expectedLen,
  ) {
    if (meta['dtype'] != 'I64') return null;
    final shape = (meta['shape'] as List?)?.cast<num>();
    if (shape == null || shape.length != 1 || shape[0].toInt() != expectedLen) {
      return null;
    }
    final offsets = (meta['data_offsets'] as List).cast<num>();
    final start = offsets[0].toInt();
    final end = offsets[1].toInt();
    if (end - start != expectedLen * 8) return null;
    final dataStart = 8 + headerLength + start;
    final dataEnd = 8 + headerLength + end;
    if (bytes.length < dataEnd) return null;
    final view = ByteData.sublistView(bytes, dataStart, dataEnd);
    final out = Int32List(expectedLen);
    for (var i = 0; i < expectedLen; i++) {
      out[i] = view.getInt64(i * 8, Endian.little);
    }
    return out;
  }

  /// Read a 1D F64 tensor of the expected length. Same graceful
  /// degradation as [_readI64Vector1D].
  static Float64List? _readF64Vector1D(
    Uint8List bytes,
    int headerLength,
    Map<String, dynamic> meta,
    int expectedLen,
  ) {
    if (meta['dtype'] != 'F64') return null;
    final shape = (meta['shape'] as List?)?.cast<num>();
    if (shape == null || shape.length != 1 || shape[0].toInt() != expectedLen) {
      return null;
    }
    final offsets = (meta['data_offsets'] as List).cast<num>();
    final start = offsets[0].toInt();
    final end = offsets[1].toInt();
    if (end - start != expectedLen * 8) return null;
    final dataStart = 8 + headerLength + start;
    final dataEnd = 8 + headerLength + end;
    if (bytes.length < dataEnd) return null;
    final view = ByteData.sublistView(bytes, dataStart, dataEnd);
    final out = Float64List(expectedLen);
    for (var i = 0; i < expectedLen; i++) {
      out[i] = view.getFloat64(i * 8, Endian.little);
    }
    return out;
  }

  /// Look up the embedding row for a single token ID.
  ///
  /// Out-of-range IDs (negative or `>= vocabSize`) yield a zero vector.
  Float32List row(int tokenId) {
    final out = Float32List(dim);
    if (tokenId < 0 || tokenId >= vocabSize) return out;
    final offset = tokenId * dim;
    for (var i = 0; i < dim; i++) {
      out[i] = weights[offset + i];
    }
    return out;
  }

  /// Mean-pool a list of token IDs, then L2-normalize.
  ///
  /// Returns a fresh `dim`-sized Float32List. Empty input returns the
  /// zero vector (no normalization — division by zero is avoided).
  /// Out-of-range IDs are silently skipped.
  ///
  /// If the safetensors shipped a `mapping` tensor, the embedding
  /// row for token `id` is taken from row `mapping[id]`. If it also
  /// shipped a `weights` tensor (SIF per-token down-weighting),
  /// each token's row is multiplied by `sifWeights[id]` before
  /// the mean. Both behaviors mirror upstream `model2vec.encode`
  /// with the default `apply_sif=True` and are essential for the
  /// dense retriever to match Python output byte-for-byte on
  /// non-ASCII code.
  Float32List encode(List<int> tokenIds) {
    final result = Float32List(dim);
    if (tokenIds.isEmpty) return result;

    final remap = mapping;
    final sif = sifWeights;
    var count = 0;
    for (final id in tokenIds) {
      if (id < 0 || id >= vocabSize) continue;
      final internalId = remap == null ? id : remap[id];
      if (internalId < 0 || internalId >= vocabSize) continue;
      final offset = internalId * dim;
      // SIF weight uses the EXTERNAL id (matching model2vec's
      // _encode_helper: `emb = emb * self.weights[id_list][:, None]`).
      final sifWeight = sif == null ? 1.0 : sif[id];
      for (var i = 0; i < dim; i++) {
        result[i] += weights[offset + i] * sifWeight;
      }
      count++;
    }
    if (count == 0) return result;

    // Mean
    final inv = 1.0 / count;
    for (var i = 0; i < dim; i++) {
      result[i] *= inv;
    }

    // L2-normalize
    var norm = 0.0;
    for (var i = 0; i < dim; i++) {
      norm += result[i] * result[i];
    }
    norm = math.sqrt(norm);
    if (norm == 0.0) return result;
    final invNorm = 1.0 / norm;
    for (var i = 0; i < dim; i++) {
      result[i] *= invNorm;
    }
    return result;
  }

  /// Cosine similarity between two `dim`-sized vectors.
  ///
  /// For L2-normalized vectors (the output of [encode]), dot product
  /// equals cosine similarity — use this directly.
  static double cosineSimilarity(Float32List a, Float32List b) {
    assert(a.length == b.length, 'vector length mismatch');
    var dot = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  @override
  String toString() =>
      'EmbeddingModel(vocabSize=$vocabSize, dim=$dim, '
      'weights=${weights.length ~/ 4} floats, '
      '${(weights.lengthInBytes / 1024 / 1024).toStringAsFixed(1)} MB)';
}