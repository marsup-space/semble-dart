import 'treesitter/languages.dart';

enum SembleContentType { code }

class SembleFileType {
  final String extension;
  final String language;
  final SembleContentType contentType;

  const SembleFileType({
    required this.extension,
    required this.language,
    this.contentType = SembleContentType.code,
  });
}

class SembleFiles {
  static bool isSupportedCodePath(String path) => typeForPath(path) != null;

  static SembleFileType? typeForPath(String path) {
    final language = LanguageRegistry.resolve(path);
    if (language == null) return null;
    return SembleFileType(extension: _extension(path), language: language);
  }

  static String _extension(String path) {
    final lower = path.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return '';
    return lower.substring(dot);
  }
}
