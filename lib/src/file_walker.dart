import 'dart:io';

import 'package:path/path.dart' as p;

import 'files.dart';

class SembleFileWalker {
  static const Set<String> defaultIgnoredDirectories = {
    '.git',
    '.dart_tool',
    '.idea',
    '.vscode',
    'build',
    'dist',
    'node_modules',
    'target',
    '.build',
  };

  final Directory root;
  final List<_IgnoreRule> _rules;

  SembleFileWalker._(this.root, this._rules);

  static Future<SembleFileWalker> create(String rootPath) async {
    final root = Directory(p.normalize(p.absolute(rootPath)));
    final rules = <_IgnoreRule>[];
    for (final name in const ['.gitignore', '.sembleignore']) {
      final file = File(p.join(root.path, name));
      if (!file.existsSync()) continue;
      rules.addAll(await _IgnoreRule.load(file));
    }
    return SembleFileWalker._(root, rules);
  }

  Future<List<String>> collectCodeFiles() async {
    if (!root.existsSync()) {
      throw ArgumentError('path does not exist: ${root.path}');
    }
    final out = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: root.path);
      if (entity is Directory) {
        continue;
      }
      if (entity is! File) continue;
      if (_isIgnored(rel)) continue;
      if (!SembleFiles.isSupportedCodePath(rel)) continue;
      out.add(p.normalize(entity.path));
    }
    out.sort();
    return out;
  }

  bool _isIgnored(String relativePath) {
    final normalized = p.posix.normalize(
      relativePath.replaceAll(p.separator, '/'),
    );
    final parts = normalized.split('/');
    if (parts.any(defaultIgnoredDirectories.contains)) return true;
    for (final rule in _rules) {
      if (rule.matches(normalized)) return true;
    }
    return false;
  }
}

class _IgnoreRule {
  final String pattern;

  const _IgnoreRule(this.pattern);

  static Future<List<_IgnoreRule>> load(File file) async {
    final lines = await file.readAsLines();
    return [
      for (final raw in lines)
        if (_parse(raw) case final pattern?) _IgnoreRule(pattern),
    ];
  }

  static String? _parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;
    if (trimmed.startsWith('!')) return null;
    return trimmed;
  }

  bool matches(String path) {
    var pat = pattern.replaceAll('\\', '/');
    final directoryOnly = pat.endsWith('/');
    if (directoryOnly) pat = pat.substring(0, pat.length - 1);
    if (pat.isEmpty) return false;

    if (!pat.contains('/')) {
      final parts = path.split('/');
      return parts.any((part) => _globMatch(part, pat));
    }

    final anchored = pat.startsWith('/');
    if (anchored) pat = pat.substring(1);
    if (directoryOnly) {
      return path == pat || path.startsWith('$pat/');
    }
    if (anchored) return _globMatch(path, pat);
    return _globMatch(path, pat) || path.endsWith('/$pat');
  }

  bool _globMatch(String value, String glob) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final ch = glob[i];
      if (ch == '*') {
        buffer.write('[^/]*');
      } else if (ch == '?') {
        buffer.write('[^/]');
      } else {
        buffer.write(RegExp.escape(ch));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString()).hasMatch(value);
  }
}
