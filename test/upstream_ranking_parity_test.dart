import 'package:semble_dart/src/fusion.dart';
import 'package:semble_dart/src/protocol.dart';
import 'package:test/test.dart';

RankedChunk _ranked(String filePath, {double bm25 = 1.0}) {
  return RankedChunk(
    chunk: SearchResult(
      filePath: filePath,
      startLine: 1,
      endLine: 1,
      score: bm25,
      content: 'def impl(): pass',
    ),
    bm25Score: bm25,
    isDefinition: true,
  );
}

void main() {
  group('upstream test_ranking.py parity', () {
    test('empty rerank input returns empty output', () {
      expect(Fusion.fuse(const [], const []), isEmpty);
    });

    for (final penalizedPath in [
      'src/semble/__init__.py',
      'tests/test_auth.py',
      'src/compat/old_api.py',
      'examples/demo.py',
      'src/types/index.d.ts',
    ]) {
      test('demotes penalized path $penalizedPath', () {
        final regular = _ranked('src/regular.py');
        final penalized = _ranked(penalizedPath);
        final results = Fusion.fuse([penalized, regular], const []);
        expect(results.first.filePath, 'src/regular.py');
      });
    }

    test('file coherence promotes top chunk of multi-chunk file', () {
      final big1 = _ranked('src/big.py', bm25: 1.0);
      final big2 = _ranked('src/big.py', bm25: 0.8);
      final small = _ranked('src/small.py', bm25: 1.0);

      final results = Fusion.fuse([small, big1, big2], const []);
      expect(results.first.filePath, 'src/big.py');
    });
  });
}
