import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:semble_dart/src/cache.dart';
import 'package:semble_dart/src/chunker.dart';
import 'package:test/test.dart';

Future<void> writeFile(String path, String contents) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

void main() {
  late Directory tempDir;
  late SembleCache cache;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('semble_cache_test_');
    cache = SembleCache(p.join(tempDir.path, 'cache'));
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('round-trips chunks while source metadata matches', () async {
    final sourcePath = p.join(tempDir.path, 'lib', 'main.dart');
    await writeFile(sourcePath, 'void main() {}\n');

    final chunks = [
      CodeChunk(
        filePath: sourcePath,
        language: 'dart',
        startLine: 1,
        endLine: 1,
        startByte: 0,
        endByte: 14,
        content: 'void main() {}',
        nodeType: 'function_signature',
        isDefinition: true,
      ),
    ];

    await cache.writeChunks(sourcePath, chunks);
    final cached = await cache.readChunks(sourcePath);

    expect(cached, hasLength(1));
    expect(cached!.single.filePath, sourcePath);
    expect(cached.single.content, 'void main() {}');
    expect(cached.single.isDefinition, isTrue);
  });

  test('returns null when the source changes', () async {
    final sourcePath = p.join(tempDir.path, 'lib', 'main.dart');
    await writeFile(sourcePath, 'void main() {}\n');
    await cache.writeChunks(sourcePath, const []);

    await Future<void>.delayed(const Duration(milliseconds: 2));
    await writeFile(sourcePath, 'void changed() {}\n');

    expect(await cache.readChunks(sourcePath), isNull);
  });

  test('returns null for missing cache or source', () async {
    final sourcePath = p.join(tempDir.path, 'lib', 'missing.dart');
    expect(await cache.readChunks(sourcePath), isNull);

    await writeFile(sourcePath, 'void main() {}\n');
    await cache.writeChunks(sourcePath, const []);
    await File(sourcePath).delete();

    expect(await cache.readChunks(sourcePath), isNull);
  });
}
