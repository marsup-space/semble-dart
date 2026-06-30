/// Upstream `semble.index.sparse.enrich_for_bm25` in Dart.
///
/// The BM25 index in upstream Python is built from a string that has
/// had the file path's stem (repeated twice for up-weighting) and the
/// last three directory components appended to the chunk content.
/// Without this enrichment, BM25 cannot pick up file-name matches
/// like "chunking" or "tokens" — which are exactly the kinds of
/// queries Crux users type ("how does chunking work?").
///
/// Mirrors `semble.index.sparse.enrich_for_bm25`:
///   f"{chunk.content} {stem} {stem} {dir_text}"
/// where `dir_text` is the last 3 directory components joined by
/// spaces, ignoring `.` and `/` root markers.
library;

import 'package:path/path.dart' as p;

/// Append file-path tokens to [content] for BM25 indexing.
///
/// The chunk's `filePath` is expected to be repo-relative (set by
/// the index build pipeline), so the bench repo's machine-specific
/// directory never leaks in.
///
/// Returns [content] unchanged if the file path is empty or root.
String enrichForBm25({required String content, required String filePath}) {
  if (filePath.isEmpty) return content;
  // Treat the input as repo-relative. Normalize separators and split
  // on `/` (the bench repo's paths use forward slashes even on
  // Windows-flavored repos; `package:path` handles both).
  final normalized = filePath.replaceAll(r'\', '/');
  final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return content;

  // The last segment is the filename. The "stem" is the filename
  // without its extension (Python's `Path.stem`).
  final filename = segments.last;
  final dot = filename.lastIndexOf('.');
  final stem = dot <= 0 ? filename : filename.substring(0, dot);

  // The last 3 directory components (upstream takes `dir_parts[-3:]`
  // after filtering out `.` and `/`). For a top-level file like
  // `chunking.py`, segments is `['chunking.py']` and there are no
  // directory parts — the trailing space is harmless.
  final dirSegments = segments.length > 1
      ? segments.sublist(0, segments.length - 1)
      : <String>[];
  final dirText = dirSegments.length > 3
      ? dirSegments.sublist(dirSegments.length - 3).join(' ')
      : dirSegments.join(' ');

  return '$content $stem $stem $dirText';
}
