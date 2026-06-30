/// Pure-Dart port of MinishLab/semble for in-process semantic code search.
///
/// Architecture: the public API in this file is consumed by the Crux main
/// isolate. The heavy work (model load, BM25, fusion) runs in a dedicated
/// search isolate — see `protocol.dart` for the wire envelope.
///
/// See `docs/design-semble-dart-port.md` in the parent Crux repo for the
/// full port plan, build order, and decision log.
library;

export 'src/protocol.dart' show SearchResult, SembleRequest, SembleResponse;
export 'src/cache.dart' show SembleCache;
export 'src/chunker.dart' show AstChunker, CodeChunk;
export 'src/file_walker.dart' show SembleFileWalker;
export 'src/files.dart' show SembleContentType, SembleFileType, SembleFiles;
export 'src/index.dart' show SembleIndex;
export 'src/treesitter/bindings.dart' show TreeSitter, TSTree;
export 'src/treesitter/languages.dart' show LanguageRegistry;
export 'src/treesitter/parser.dart' show ParsedSource, TreeSitterParser;
