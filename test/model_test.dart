import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:semble_dart/src/model.dart';
import 'package:test/test.dart';

/// Build a minimal valid safetensors byte buffer containing a single
/// F32 tensor of [shape[0], shape[1]] = [rows, cols] with the given
/// [values]. Returns the bytes for [EmbeddingModel.fromBytes] to parse.
Uint8List _makeSafetensors(List<List<double>> values, {String name = 'emb'}) {
  final rows = values.length;
  final cols = values.isEmpty ? 0 : values.first.length;
  final totalFloats = rows * cols;
  final totalBytes = totalFloats * 4;

  // Build tensor data as a single Float32List (row-major).
  final data = Float32List(totalFloats);
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      data[r * cols + c] = values[r][c];
    }
  }
  final dataBytes = data.buffer.asUint8List();

  // Build header JSON: { tensor_name: { dtype, shape, data_offsets } }.
  final headerJson = {
    name: {
      'dtype': 'F32',
      'shape': [rows, cols],
      'data_offsets': [0, totalBytes],
    },
  };
  final headerStr = jsonEncode(headerJson);
  final headerBytes = utf8.encode(headerStr);
  final headerLength = headerBytes.length;

  // Assemble: [u64 LE header length][header bytes][tensor data].
  final out = BytesBuilder();
  final lengthBytes = ByteData(8)..setUint64(0, headerLength, Endian.little);
  out.add(lengthBytes.buffer.asUint8List());
  out.add(headerBytes);
  out.add(dataBytes);
  return out.toBytes();
}

void main() {
  group('EmbeddingModel.fromBytes', () {
    test('parses a minimal 2x3 safetensors payload', () {
      final bytes = _makeSafetensors([
        [1.0, 2.0, 3.0],
        [4.0, 5.0, 6.0],
      ]);
      final m = EmbeddingModel.fromBytes(bytes);
      expect(m.vocabSize, 2);
      expect(m.dim, 3);
      expect(m.weights.length, 6);
      expect(m.weights[0], 1.0);
      expect(m.weights[1], 2.0);
      expect(m.weights[5], 6.0);
    });

    test('preserves row order (row 0 = token 0)', () {
      final bytes = _makeSafetensors([
        [10.0, 11.0],
        [20.0, 21.0],
        [30.0, 31.0],
      ]);
      final m = EmbeddingModel.fromBytes(bytes);
      expect(m.row(0), [10.0, 11.0]);
      expect(m.row(1), [20.0, 21.0]);
      expect(m.row(2), [30.0, 31.0]);
    });

    test('rejects non-F32 dtype', () {
      // Hand-craft a header that claims F16.
      final headerJson = {
        'emb': {
          'dtype': 'F16',
          'shape': [2, 2],
          'data_offsets': [0, 8],
        },
      };
      final headerBytes = utf8.encode(jsonEncode(headerJson));
      final lengthBytes =
          ByteData(8)..setUint64(0, headerBytes.length, Endian.little);
      final data = Uint8List(8); // 4 F16 = 8 bytes
      final out = BytesBuilder()
        ..add(lengthBytes.buffer.asUint8List())
        ..add(headerBytes)
        ..add(data);
      expect(
        () => EmbeddingModel.fromBytes(out.toBytes()),
        throwsArgumentError,
      );
    });

    test('rejects 1D tensor', () {
      final headerJson = {
        'emb': {
          'dtype': 'F32',
          'shape': [4],
          'data_offsets': [0, 16],
        },
      };
      final headerBytes = utf8.encode(jsonEncode(headerJson));
      final lengthBytes =
          ByteData(8)..setUint64(0, headerBytes.length, Endian.little);
      final data = Uint8List(16);
      final out = BytesBuilder()
        ..add(lengthBytes.buffer.asUint8List())
        ..add(headerBytes)
        ..add(data);
      expect(
        () => EmbeddingModel.fromBytes(out.toBytes()),
        throwsArgumentError,
      );
    });

    test('rejects truncated buffer', () {
      // Header says 16 bytes of data, only 8 present.
      final headerJson = {
        'emb': {
          'dtype': 'F32',
          'shape': [2, 2],
          'data_offsets': [0, 16],
        },
      };
      final headerBytes = utf8.encode(jsonEncode(headerJson));
      final lengthBytes =
          ByteData(8)..setUint64(0, headerBytes.length, Endian.little);
      final data = Uint8List(8); // only 8 bytes, not 16
      final out = BytesBuilder()
        ..add(lengthBytes.buffer.asUint8List())
        ..add(headerBytes)
        ..add(data);
      expect(
        () => EmbeddingModel.fromBytes(out.toBytes()),
        throwsArgumentError,
      );
    });

    test('rejects buffer too short for header length', () {
      final lengthBytes =
          ByteData(8)..setUint64(0, 9999, Endian.little);
      final out = BytesBuilder()
        ..add(lengthBytes.buffer.asUint8List())
        ..add(Uint8List(10));
      expect(
        () => EmbeddingModel.fromBytes(out.toBytes()),
        throwsArgumentError,
      );
    });

    test('skips __metadata__ entry when locating the tensor', () {
      // Real safetensors files include __metadata__ before the tensors.
      final headerJson = {
        '__metadata__': {'format': 'pt'},
        'emb': {
          'dtype': 'F32',
          'shape': [1, 2],
          'data_offsets': [0, 8],
        },
      };
      final headerBytes = utf8.encode(jsonEncode(headerJson));
      final lengthBytes =
          ByteData(8)..setUint64(0, headerBytes.length, Endian.little);
      final data = Float32List.fromList([42.0, 43.0]);
      final out = BytesBuilder()
        ..add(lengthBytes.buffer.asUint8List())
        ..add(headerBytes)
        ..add(data.buffer.asUint8List());
      final m = EmbeddingModel.fromBytes(out.toBytes());
      expect(m.row(0), [42.0, 43.0]);
    });

    test('prefers tensor named "embeddings" over other F32 2D tensors', () {
      // Real model2vec files (potion-code-16M) ship 3 tensors:
      // mapping (I64), weights (F64), embeddings (F32). We want the
      // explicit embeddings one, not the first 2D F32 — even though
      // here we use a synthetic F32 helper before embeddings in the
      // header, the loader should still pick embeddings by name.
      final headerJson = {
        'mapping': {
          'dtype': 'I64',
          'shape': [4],
          'data_offsets': [0, 32],
        },
        'weights': {
          'dtype': 'F64',
          'shape': [4],
          'data_offsets': [32, 64],
        },
        'other_f32': {
          'dtype': 'F32',
          'shape': [2, 2],
          'data_offsets': [64, 80],
        },
        'embeddings': {
          'dtype': 'F32',
          'shape': [2, 2],
          'data_offsets': [80, 96],
        },
      };
      final headerBytes = utf8.encode(jsonEncode(headerJson));
      final lengthBytes =
          ByteData(8)..setUint64(0, headerBytes.length, Endian.little);
      // padding 64 bytes (32 + 32) then two F32x4 tensors (16+16).
      final data = BytesBuilder()
        ..add(Uint8List(32)) // mapping
        ..add(Float64List(4).buffer.asUint8List()) // weights
        ..add(Float32List.fromList([1.0, 2.0, 3.0, 4.0]).buffer.asUint8List())
        ..add(Float32List.fromList([99.0, 98.0, 97.0, 96.0])
            .buffer.asUint8List());
      final out = BytesBuilder()
        ..add(lengthBytes.buffer.asUint8List())
        ..add(headerBytes)
        ..add(data.toBytes());
      final m = EmbeddingModel.fromBytes(out.toBytes());
      expect(m.row(0), [99.0, 98.0]);
      expect(m.row(1), [97.0, 96.0]);
    });

    test('falls back to first 2D F32 tensor when no "embeddings" entry',
        () {
      // For non-model2vec safetensors files that have a single
      // differently-named F32 2D tensor, the loader should still
      // pick it up rather than reject the file.
      final headerJson = {
        'my_matrix': {
          'dtype': 'F32',
          'shape': [1, 2],
          'data_offsets': [0, 8],
        },
      };
      final headerBytes = utf8.encode(jsonEncode(headerJson));
      final lengthBytes =
          ByteData(8)..setUint64(0, headerBytes.length, Endian.little);
      final data = Float32List.fromList([7.0, 8.0]);
      final out = BytesBuilder()
        ..add(lengthBytes.buffer.asUint8List())
        ..add(headerBytes)
        ..add(data.buffer.asUint8List());
      final m = EmbeddingModel.fromBytes(out.toBytes());
      expect(m.row(0), [7.0, 8.0]);
    });

    test('rejects buffer with no tensor entries', () {
      // Only I64 + F64 tensors — no F32 anywhere. Loader should
      // refuse rather than silently pick a wrong-type tensor.
      final headerJson = {
        '__metadata__': {'format': 'pt'},
        'mapping': {
          'dtype': 'I64',
          'shape': [4],
          'data_offsets': [0, 32],
        },
        'weights': {
          'dtype': 'F64',
          'shape': [4],
          'data_offsets': [32, 64],
        },
      };
      final headerBytes = utf8.encode(jsonEncode(headerJson));
      final lengthBytes =
          ByteData(8)..setUint64(0, headerBytes.length, Endian.little);
      final data = BytesBuilder()
        ..add(Uint8List(32))
        ..add(Float64List(4).buffer.asUint8List());
      final out = BytesBuilder()
        ..add(lengthBytes.buffer.asUint8List())
        ..add(headerBytes)
        ..add(data.toBytes());
      expect(
        () => EmbeddingModel.fromBytes(out.toBytes()),
        throwsArgumentError,
      );
    });
  });

  group('EmbeddingModel.row', () {
    late EmbeddingModel m;

    setUp(() {
      m = EmbeddingModel.fromBytes(_makeSafetensors([
        [1.0, 0.0],
        [0.0, 1.0],
        [1.0, 1.0],
      ]));
    });

    test('returns row for in-range token', () {
      expect(m.row(0), [1.0, 0.0]);
      expect(m.row(1), [0.0, 1.0]);
    });

    test('returns zeros for negative token id', () {
      expect(m.row(-1), [0.0, 0.0]);
    });

    test('returns zeros for out-of-range token id', () {
      expect(m.row(100), [0.0, 0.0]);
    });
  });

  group('EmbeddingModel.encode', () {
    late EmbeddingModel m;

    setUp(() {
      // 4-row matrix with orthogonal unit-ish rows so we can verify
      // math by hand:
      //   row 0 = [3, 4]    (norm 5)
      //   row 1 = [0, 0]    (zero — will be skipped via out-of-range)
      //   row 2 = [1, 0]    (norm 1)
      //   row 3 = [0, 2]    (norm 2)
      m = EmbeddingModel.fromBytes(_makeSafetensors([
        [3.0, 4.0],
        [0.0, 0.0],
        [1.0, 0.0],
        [0.0, 2.0],
      ]));
    });

    test('single token returns L2-normalized row', () {
      // row 0 = [3,4], norm 5 → [0.6, 0.8]
      final v = m.encode([0]);
      expect(v, [closeTo(0.6, 1e-6), closeTo(0.8, 1e-6)]);
    });

    test('multiple tokens: mean then L2-normalize', () {
      // rows 2,3 → [1,0]+[0,2] = [1,2], mean = [0.5, 1.0]
      // norm = sqrt(0.25+1) = sqrt(1.25) ≈ 1.118
      // normalized = [0.5/1.118, 1.0/1.118] ≈ [0.4472, 0.8944]
      final v = m.encode([2, 3]);
      expect(v[0], closeTo(0.5 / math.sqrt(1.25), 1e-5));
      expect(v[1], closeTo(1.0 / math.sqrt(1.25), 1e-5));
    });

    test('skips out-of-range token ids', () {
      // token 99 → out-of-range; only token 0 contributes
      final v = m.encode([99, 0]);
      expect(v, [closeTo(0.6, 1e-6), closeTo(0.8, 1e-6)]);
    });

    test('empty input → zero vector, no normalization', () {
      final v = m.encode([]);
      expect(v, [0.0, 0.0]);
    });

    test('all out-of-range tokens → zero vector, no normalization', () {
      final v = m.encode([-1, 99, 1000]);
      expect(v, [0.0, 0.0]);
    });

    test('repeated token is mean-pooled with itself', () {
      // encode([0, 0]) = mean([3,4], [3,4]) = [3,4] → norm 5 → [0.6, 0.8]
      final v = m.encode([0, 0]);
      expect(v, [closeTo(0.6, 1e-6), closeTo(0.8, 1e-6)]);
    });
  });

  group('EmbeddingModel.cosineSimilarity', () {
    test('identical L2-normalized vectors → 1.0', () {
      final a = Float32List.fromList([0.6, 0.8]);
      final b = Float32List.fromList([0.6, 0.8]);
      expect(EmbeddingModel.cosineSimilarity(a, b), closeTo(1.0, 1e-6));
    });

    test('orthogonal L2-normalized vectors → 0.0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([0.0, 1.0]);
      expect(EmbeddingModel.cosineSimilarity(a, b), closeTo(0.0, 1e-6));
    });

    test('opposite L2-normalized vectors → -1.0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([-1.0, 0.0]);
      expect(EmbeddingModel.cosineSimilarity(a, b), closeTo(-1.0, 1e-6));
    });

    test('non-normalized vectors: just dot product', () {
      // [3,4] · [3,4] = 25; not 1.0 because the vectors aren't unit-norm.
      final a = Float32List.fromList([3.0, 4.0]);
      final b = Float32List.fromList([3.0, 4.0]);
      expect(EmbeddingModel.cosineSimilarity(a, b), closeTo(25.0, 1e-6));
    });
  });

  group('EmbeddingModel.fromFile', () {
    test('roundtrips through disk', () async {
      // Write to a temp file, load back, verify identical weights.
      final original = _makeSafetensors([
        [1.5, 2.5, 3.5],
        [4.5, 5.5, 6.5],
      ]);
      final tmp = await Directory.systemTemp.createTemp('semble_model_test_');
      addTearDown(() => tmp.delete(recursive: true));
      final path = '${tmp.path}/model.safetensors';
      await File(path).writeAsBytes(original);

      final m = await EmbeddingModel.fromFile(path);
      expect(m.vocabSize, 2);
      expect(m.dim, 3);
      expect(m.row(0), [1.5, 2.5, 3.5]);
      expect(m.row(1), [4.5, 5.5, 6.5]);
    });
  });
}