import 'package:test/test.dart';

void main() {
  group('upstream test scope', () {
    test('documents intentionally skipped upstream areas', () {
      // These upstream suites exercise product surfaces that are outside the
      // Crux-native Dart port v1: Python CLI installer behavior, MCP server
      // mode, savings stats, git-URL indexing, and docs/config/data indexing.
      // Core code-search parity is covered by the dedicated upstream_* tests.
      expect([
        'tests/test_cli.py',
        'tests/test_installer.py',
        'tests/test_mcp.py',
        'tests/test_stats.py',
        'docs/config/data content modes',
        'SembleIndex.from_git',
      ], isNotEmpty);
    });
  });
}
