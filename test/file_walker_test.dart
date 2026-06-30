import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:semble_dart/src/file_walker.dart';
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

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('semble_walker_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('collectCodeFiles returns supported files sorted', () async {
    await writeFile(tempDir, 'lib/b.py', 'print("b")');
    await writeFile(tempDir, 'lib/a.dart', 'void main() {}');
    await writeFile(tempDir, 'README.md', '# docs');

    final walker = await SembleFileWalker.create(tempDir.path);
    final files = await walker.collectCodeFiles();

    expect(files.map((f) => p.relative(f, from: tempDir.path)), [
      p.join('lib', 'a.dart'),
      p.join('lib', 'b.py'),
    ]);
  });

  test('collectCodeFiles skips default ignored directories', () async {
    await writeFile(tempDir, 'lib/main.dart', 'void main() {}');
    await writeFile(tempDir, '.git/hooks/post-commit.dart', 'ignored');
    await writeFile(tempDir, 'node_modules/pkg/index.js', 'ignored');
    await writeFile(tempDir, 'build/generated.dart', 'ignored');

    final walker = await SembleFileWalker.create(tempDir.path);
    final files = await walker.collectCodeFiles();
    final relative = files.map((f) => p.relative(f, from: tempDir.path));

    expect(relative, [p.join('lib', 'main.dart')]);
  });

  test('collectCodeFiles respects .gitignore and .sembleignore', () async {
    await writeFile(tempDir, '.gitignore', '*.g.dart\nignored_dir/\n');
    await writeFile(tempDir, '.sembleignore', 'private/*.dart\n');
    await writeFile(tempDir, 'lib/main.dart', 'void main() {}');
    await writeFile(tempDir, 'lib/generated.g.dart', 'ignored');
    await writeFile(tempDir, 'ignored_dir/file.py', 'ignored');
    await writeFile(tempDir, 'private/secret.dart', 'ignored');

    final walker = await SembleFileWalker.create(tempDir.path);
    final files = await walker.collectCodeFiles();
    final relative = files.map((f) => p.relative(f, from: tempDir.path));

    expect(relative, [p.join('lib', 'main.dart')]);
  });

  test('create throws cleanly when root does not exist', () async {
    final walker = await SembleFileWalker.create(
      p.join(tempDir.path, 'missing'),
    );
    expect(walker.collectCodeFiles, throwsArgumentError);
  });
}
