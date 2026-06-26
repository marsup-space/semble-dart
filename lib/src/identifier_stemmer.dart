/// Split identifiers into component stems for BM25 scoring and the
/// "identifier stems" rerank signal in [fusion.dart].
///
/// Examples:
///   parseConfig      → ['parse', 'config']
///   ConfigParser     → ['config', 'parser']
///   XMLParser        → ['xml', 'parser']
///   JSONConfig       → ['json', 'config']
///   config_parser    → ['config', 'parser']
///   _private         → ['private']
///   getUserById42    → ['get', 'user', 'by', 'id', '42']
///   Foo::bar         → ['foo', 'bar']
///
/// All output is lowercased. Empty / pure-separator inputs return an
/// empty list — the caller decides whether to treat such "documents"
/// as noise (BM25 skips empty token lists cleanly).
///
/// Algorithm:
///   1. Split on runs of non-alphanumeric chars (underscores, `::`,
///      dots, dashes, etc.)
///   2. Within each piece, split on three boundary classes:
///        - lower|digit → upper   (camelCase)
///        - upper → upper + lower (acronym → word, e.g. XML|Parser)
///        - letter ↔ digit         (id42, foo123)
///   3. Drop empty pieces, lowercase the rest.
library;

class IdentifierStemmer {
  /// Lowercase / digit → uppercase transition (camelCase boundary).
  static final _camel = RegExp(r'(?<=[a-z0-9])(?=[A-Z])');

  /// Uppercase → uppercase + lowercase transition (acronym boundary).
  /// Matches `XMLParser` between `L` and `P` (lookahead is `Pa`, i.e.
  /// uppercase followed by lowercase), yielding `XML` + `Parser`.
  static final _acronym = RegExp(r'(?<=[A-Z])(?=[A-Z][a-z])');

  /// Letter ↔ digit boundary in both directions: `id42` → `id` + `42`,
  /// `foo123bar` → `foo` + `123` + `bar`.
  static final _digit = RegExp(r'(?<=[a-zA-Z])(?=\d)|(?<=\d)(?=[a-zA-Z])');

  /// Non-alphanumeric separator: underscores, `::`, `.`, `-`, etc.
  static final _separator = RegExp(r'[^a-zA-Z0-9]+');

  /// Run of whitespace produced by the boundary replacements.
  static final _whitespace = RegExp(r'\s+');

  const IdentifierStemmer();

  /// Split [identifier] into lowercased component stems.
  List<String> stems(String identifier) {
    if (identifier.isEmpty) return const [];

    final result = <String>[];
    for (final part in identifier.split(_separator)) {
      if (part.isEmpty) continue;
      final split = part
          .replaceAll(_camel, ' ')
          .replaceAll(_acronym, ' ')
          .replaceAll(_digit, ' ');
      for (final word in split.split(_whitespace)) {
        if (word.isNotEmpty) result.add(word.toLowerCase());
      }
    }
    return result;
  }
}