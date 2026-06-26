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

  const EmbeddingModel._({
    required this.weights,
    required this.vocabSize,
    required this.dim,
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

    // Find the first non-metadata tensor. For potion-code-16M there's
    // exactly one tensor (the embedding matrix).
    Map<String, dynamic>? tensorMeta;
    String? tensorName;
    for (final entry in headerJson.entries) {
      if (entry.key == '__metadata__') continue;
      tensorMeta = entry.value as Map<String, dynamic>;
      tensorName = entry.key;
      break;
    }
    if (tensorMeta == null || tensorName == null) {
      throw ArgumentError('safetensors file has no tensor entries');
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

    return EmbeddingModel._(
      weights: weights,
      vocabSize: vocabSize,
      dim: dim,
    );
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
  Float32List encode(List<int> tokenIds) {
    final result = Float32List(dim);
    if (tokenIds.isEmpty) return result;

    var count = 0;
    for (final id in tokenIds) {
      if (id < 0 || id >= vocabSize) continue;
      final offset = id * dim;
      for (var i = 0; i < dim; i++) {
        result[i] += weights[offset + i];
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