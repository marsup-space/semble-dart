// Tests for `enrichForBm25` — the Dart port of upstream Python's
// `semble.index.sparse.enrich_for_bm25`. Each test feeds the same
// inputs to both implementations and asserts byte-equal output.
import 'dart:io';

import 'package:semble_dart/src/sparse.dart';
import 'package:test/test.dart';

/// Run the upstream Python function and return its output for the
/// given inputs. Skips the test (with a clear message) if the
/// Python venv is unavailable on this machine.
String? _pythonEnrich(String content, String filePath) {
  // The test harness runs `dart test` from the package root. We
  // shell out to Python via the same venv used by the bench, so the
  // test stays self-contained. If the venv is missing (e.g. on CI
  // runners without the bench repo), skip.
  const venvPython =
      '/Users/wuhao/Projects/crux/.research/semble/.bench-venv/bin/python';
  try {
    final result = Process.runSync(venvPython, [
      '-c',
      'import sys; '
          'sys.path.insert(0, "/Users/wuhao/Projects/crux/.research/semble/src"); '
          'from pathlib import Path; '
          'from semble.types import Chunk; '
          'from semble.index.sparse import enrich_for_bm25; '
          'c = Chunk(content=sys.argv[1], file_path=sys.argv[2], '
          'start_line=0, end_line=0, language="python"); '
          'print(enrich_for_bm25(c), end="")',
      content,
      filePath,
    ]);
    if (result.exitCode != 0) return null;
    return result.stdout as String;
  } catch (_) {
    return null;
  }
}

void main() {
  group('enrichForBm25', () {
    test('appends stem twice + last 3 dir components', () {
      final out = enrichForBm25(
        content: 'def foo(): pass',
        filePath: 'src/semble/chunking/chunking.py',
      );
      expect(
        out,
        'def foo(): pass chunking chunking src semble chunking',
      );
    });

    test('top-level file (no dirs) → stem only, with trailing space', () {
      // Python's `f"{content} {stem} {stem} {dir_text}"` always
      // emits a trailing space when there are no directory
      // components. The token() then sees a trailing space and
      // produces no extra token — so the trailing space is
      // harmless. The parity tests below confirm Python emits
      // the same.
      final out = enrichForBm25(
        content: 'print(1)',
        filePath: 'README.md',
      );
      expect(out, 'print(1) README README ');
    });

    test('empty content → still gets path tokens', () {
      final out = enrichForBm25(
        content: '',
        filePath: 'src/cache.py',
      );
      expect(out, ' cache cache src');
    });

    test('empty filePath → content unchanged', () {
      final out = enrichForBm25(content: 'foo()', filePath: '');
      expect(out, 'foo()');
    });

    test('file with no extension → whole filename as stem', () {
      final out = enrichForBm25(
        content: 'x',
        filePath: 'src/Makefile',
      );
      expect(out, 'x Makefile Makefile src');
    });

    test('filePath that is just a filename', () {
      final out = enrichForBm25(
        content: 'y',
        filePath: 'chunking.py',
      );
      expect(out, 'y chunking chunking ');
    });

    test('deep path → only last 3 dir components', () {
      final out = enrichForBm25(
        content: 'q',
        filePath: 'a/b/c/d/e/file.py',
      );
      // Last 3 dirs: c, d, e
      expect(out, 'q file file c d e');
    });
  });

  group('enrichForBm25 (parity with upstream Python)', () {
    // Each test runs the SAME inputs through the Python venv's
    // `enrich_for_bm25` and asserts the output is byte-identical.
    // Skipped (not failed) when the venv is unavailable.

    test('src/semble/chunking/chunking.py ↔ Python', () {
      final py = _pythonEnrich(
        'def chunk_source(source, file_path, language): pass',
        'src/semble/chunking/chunking.py',
      );
      if (py == null) {
        markTestSkipped('Python venv not available');
        return;
      }
      final dart = enrichForBm25(
        content: 'def chunk_source(source, file_path, language): pass',
        filePath: 'src/semble/chunking/chunking.py',
      );
      expect(dart, py);
    });

    test('README.md (top-level) ↔ Python', () {
      final py = _pythonEnrich('hi', 'README.md');
      if (py == null) {
        markTestSkipped('Python venv not available');
        return;
      }
      final dart = enrichForBm25(content: 'hi', filePath: 'README.md');
      expect(dart, py);
    });

    test('deep path ↔ Python', () {
      final py = _pythonEnrich('q', 'a/b/c/d/e/f.py');
      if (py == null) {
        markTestSkipped('Python venv not available');
        return;
      }
      final dart = enrichForBm25(content: 'q', filePath: 'a/b/c/d/e/f.py');
      expect(dart, py);
    });
  });
}
