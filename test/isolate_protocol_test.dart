import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:semble_dart/semble_dart.dart';
import 'package:test/test.dart';

Future<void> writeFile(
  Directory root,
  String relativePath,
  String contents,
) async {
  final file = File(p.join(root.path, relativePath));
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

void main() {
  late Directory tempDir;
  late SembleSearchIsolate searchIsolate;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('semble_isolate_test_');
    await writeFile(
      tempDir,
      'lib/auth.dart',
      'class AuthClient { Future<void> refreshToken() async {} }\n',
    );
    await writeFile(
      tempDir,
      'lib/config.dart',
      'class ConfigReader { void readConfig() {} }\n',
    );

    searchIsolate = await SembleSearchIsolate.spawn(
      modelPath: '',
      tokenizerPath: '',
      grammarsLibPath: '',
    );
  });

  tearDown(() async {
    await searchIsolate.shutdown();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('spawn prewarm search findRelated shutdown lifecycle', () async {
    await searchIsolate.prewarm(tempDir.path);

    final hits = await searchIsolate.search(
      'refresh token',
      path: tempDir.path,
      topK: 1,
    );

    expect(hits, hasLength(1));
    expect(hits.single.filePath, endsWith(p.join('lib', 'auth.dart')));

    final related = await searchIsolate.findRelated(
      file: hits.single.filePath,
      line: hits.single.startLine,
      path: tempDir.path,
      topK: 2,
    );

    expect(
      related.map((r) => r.filePath),
      isNot(contains(hits.single.filePath)),
    );
  });
}
