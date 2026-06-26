# semble_dart

Pure-Dart port of [MinishLab/semble](https://github.com/MinishLab/semble) for in-process semantic code search.

Used by [Crux](https://github.com/marsup-space/crux) as the implementation behind the `semantic_search` and `find_similar_code` agent tools. See the parent repo's `docs/design-semble-dart-port.md` for the port plan, architecture, and decision log.

## Status

Track A (pure-Dart pieces) in progress. The package is not yet wired into Crux — that happens in Track E.

## License

MIT — same as upstream MinishLab/semble and the bundled `potion-code-16M` model.