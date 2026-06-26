/// Pure-Dart port of MinishLab/semble for in-process semantic code search.
///
/// Architecture: the public API in this file is consumed by the Crux main
/// isolate. The heavy work (model load, BM25, fusion) runs in a dedicated
/// search isolate — see [isolateClient] for the spawn/facade entry point
/// and `protocol.dart` for the wire envelope.
///
/// See `docs/design-semble-dart-port.md` in the parent Crux repo for the
/// full port plan, build order, and decision log.
library;

export 'src/protocol.dart' show SearchResult, SembleRequest, SembleResponse;