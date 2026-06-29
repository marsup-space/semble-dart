/// File extension → tree-sitter grammar registry.
///
/// Maps each supported code file extension to the `tree_sitter_<x>()`
/// symbol exposed by `libcrux_grammars`. Call [resolve] with a
/// `path` or `extension` to get the grammar name to pass to
/// [TreeSitter.registerLanguage] / [TreeSitter.parse].
library;

class LanguageRegistry {
  /// `.ext` (lowercase, including the dot) → grammar name as
  /// exposed by the dylib.
  static const Map<String, String> _byExtension = {
    '.dart': 'dart',
    '.py': 'python',
    '.pyi': 'python', // Python type stubs
    '.js': 'javascript',
    '.jsx': 'javascript', // JSX → javascript grammar
    '.mjs': 'javascript',
    '.cjs': 'javascript',
    '.ts': 'typescript',
    '.tsx': 'tsx',
    '.go': 'go',
    '.rs': 'rust',
    '.java': 'java',
    '.c': 'cpp',
    '.h': 'cpp',
    '.cpp': 'cpp',
    '.cc': 'cpp',
    '.cxx': 'cpp',
    '.c++': 'cpp',
    '.hpp': 'cpp',
    '.hh': 'cpp',
    '.hxx': 'cpp',
    '.rb': 'ruby',
    '.php': 'php',
    '.phtml': 'php', // HTML-embedded PHP
    '.phps': 'php_only', // pure PHP (no HTML)
  };

  /// All supported extensions (lowercase, with leading dot). Not
  /// `const` because `Map.keys` is not a const-evaluable property;
  /// computed lazily on first access.
  static final Set<String> supportedExtensions = _byExtension.keys.toSet();

  /// All grammar names exposed by the dylib. (For introspection /
  /// `--list-grammars`-style tooling.)
  static const Set<String> supportedGrammars = {
    'dart',
    'python',
    'javascript',
    'typescript',
    'tsx',
    'go',
    'rust',
    'java',
    'cpp',
    'ruby',
    'php',
    'php_only',
  };

  /// Look up the grammar name for a file path or extension.
  ///
  /// [pathOrExt] can be:
  ///   - a file path: `/foo/bar/main.dart` → 'dart'
  ///   - an extension with dot: `.dart` → 'dart'
  ///   - an extension without dot: `dart` → 'dart' (auto-prepends `.`)
  ///
  /// Returns null if the extension is not supported.
  static String? resolve(String pathOrExt) {
    final lower = pathOrExt.toLowerCase();
    if (_byExtension.containsKey(lower)) return _byExtension[lower];
    // Maybe it's a path — extract the last `.ext` segment.
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = lower.substring(dot);
    return _byExtension[ext];
  }

  /// Same as [resolve] but throws if the extension is unsupported.
  static String require(String pathOrExt) {
    final r = resolve(pathOrExt);
    if (r == null) {
      throw ArgumentError('unsupported file type: $pathOrExt '
          '(supported: ${_byExtension.keys.join(", ")})');
    }
    return r;
  }
}