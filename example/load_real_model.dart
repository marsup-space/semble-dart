// Quick sanity: load the real potion-code-16M model from local HF cache,
// encode a few token sequences, verify the embeddings come out
// L2-normalized to 1.0 and cosine similarity behaves.
//
// Run from inside the submodule: dart run example/load_real_model.dart

import 'dart:io';
import 'dart:math' as math;

import 'package:semble_dart/src/model.dart';

Future<void> main() async {
  final home = Platform.environment['HOME']!;
  final modelPath =
      '$home/.cache/huggingface/hub/models--minishlab--potion-code-16M/'
      'snapshots/86848193a842865570d9c8d3e7d268b66ab52752/model.safetensors';

  print('Loading $modelPath ...');
  final model = await EmbeddingModel.fromFile(modelPath);
  print(model);

  // Encode a single token (real token 100 = some arbitrary vocab entry).
  final v1 = model.encode([100]);
  final norm1 = math.sqrt(v1.fold<double>(0, (s, x) => s + x * x));
  print(
    '\nsingle token [100] L2 norm: ${norm1.toStringAsFixed(6)} '
    '(should be 1.0)',
  );

  // Encode a phrase-equivalent: many copies of the same token. Should
  // still L2-normalize to 1.0.
  final v2 = model.encode([100, 100, 100, 100, 100]);
  final norm2 = math.sqrt(v2.fold<double>(0, (s, x) => s + x * x));
  print(
    'repeat token x5 L2 norm:    ${norm2.toStringAsFixed(6)} '
    '(should be 1.0)',
  );

  // Cosine similarity of a token to itself = 1.0.
  final v3 = model.encode([42, 42, 42]);
  final v4 = model.encode([42, 42, 42]);
  final cos = EmbeddingModel.cosineSimilarity(v3, v4);
  print(
    'cos(token42-mean, token42-mean) = ${cos.toStringAsFixed(6)} '
    '(should be 1.0)',
  );

  // Cosine similarity of two different tokens — typically small positive
  // for semantically related tokens, near zero for unrelated.
  final va = model.encode([100, 200]);
  final vb = model.encode([1000, 2000]);
  final cos2 = EmbeddingModel.cosineSimilarity(va, vb);
  print(
    'cos(tokens[100,200], tokens[1000,2000]) = '
    '${cos2.toStringAsFixed(6)}',
  );
}
