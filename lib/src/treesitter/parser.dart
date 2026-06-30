import 'dart:io';

import 'bindings.dart';
import 'languages.dart';

/// High-level parser facade over [TreeSitter].
///
/// It resolves a file's grammar from [LanguageRegistry], registers the
/// grammar lazily, and returns an owned [ParsedSource]. Call [ParsedSource.close]
/// when done so the native tree is released.
class TreeSitterParser {
  final TreeSitter treeSitter;

  TreeSitterParser(this.treeSitter);

  Future<ParsedSource> parseFile(String path) async {
    final source = await File(path).readAsString();
    return parseSource(path: path, source: source);
  }

  ParsedSource parseSource({required String path, required String source}) {
    final language = LanguageRegistry.require(path);
    treeSitter.registerLanguage(language);
    final tree = treeSitter.parse(source, language: language);
    return ParsedSource(
      path: path,
      language: language,
      source: source,
      tree: tree,
    );
  }
}

class ParsedSource {
  final String path;
  final String language;
  final String source;
  final TSTree tree;

  const ParsedSource({
    required this.path,
    required this.language,
    required this.source,
    required this.tree,
  });

  TSNode root() => tree.root();

  void close() => tree.close();
}
