import 'treesitter/bindings.dart';
import 'treesitter/parser.dart';

/// A source chunk ready for indexing.
class CodeChunk {
  final String filePath;
  final String language;
  final int startLine;
  final int endLine;
  final int startByte;
  final int endByte;
  final String content;
  final String nodeType;
  final bool isDefinition;

  const CodeChunk({
    required this.filePath,
    required this.language,
    required this.startLine,
    required this.endLine,
    required this.startByte,
    required this.endByte,
    required this.content,
    required this.nodeType,
    required this.isDefinition,
  });

  /// Copy with a subset of fields overridden. Used by
  /// [SembleIndex.fromPath] to rewrite the chunk's [filePath] from
  /// absolute to repo-relative after the chunker emits it, without
  /// disturbing the other fields (which were already validated by
  /// the chunker).
  CodeChunk copyWith({
    String? filePath,
    String? language,
    int? startLine,
    int? endLine,
    int? startByte,
    int? endByte,
    String? content,
    String? nodeType,
    bool? isDefinition,
  }) {
    return CodeChunk(
      filePath: filePath ?? this.filePath,
      language: language ?? this.language,
      startLine: startLine ?? this.startLine,
      endLine: endLine ?? this.endLine,
      startByte: startByte ?? this.startByte,
      endByte: endByte ?? this.endByte,
      content: content ?? this.content,
      nodeType: nodeType ?? this.nodeType,
      isDefinition: isDefinition ?? this.isDefinition,
    );
  }
}

/// AST-aware chunker backed by tree-sitter.
///
/// Track B keeps this intentionally conservative: split on top-level named
/// nodes and merge adjacent small nodes when a grammar exposes signature/body
/// as siblings. Track C can enrich this with language-specific strategies once
/// indexing and search are in place.
class AstChunker {
  static const int defaultDesiredChunkBytes = 750;
  static const int minRecursiveChunkBytes = 50;
  static const int maxRecursionDepth = 500;
  /// Hard upper cap on chunk size in bytes. When a node exceeds this and
  /// cannot be split further by the AST recursion, it is split along line
  /// boundaries. This prevents degenerate mega-chunks (e.g., a 1360-line
  /// class) from being emitted as a single result, which bloats context
  /// and degrades search quality.
  static const int hardMaxChunkBytes = 2000;

  final TreeSitter treeSitter;
  final int desiredChunkBytes;

  const AstChunker({
    required this.treeSitter,
    this.desiredChunkBytes = defaultDesiredChunkBytes,
  });

  List<CodeChunk> chunk(ParsedSource parsed) {
    if (parsed.source.trim().isEmpty) return const [];

    final root = parsed.root();
    final ranges = _mergeNode(root, 0);
    // Enforce hard cap using source text for line-boundary splits.
    final bounded = _enforceHardCap(ranges, parsed.source);
    return [for (final range in bounded) _chunkForRange(parsed, range)];
  }

  bool _hasContent(TSNode node) =>
      treeSitter.endByte(node) > treeSitter.startByte(node);

  List<_NodeRange> _mergeNode(TSNode node, int depth) {
    final raw = _mergeNodeInner(node, depth);
    if (raw.isEmpty) return raw;
    return _mergeAdjacent(raw);
  }

  List<_NodeRange> _mergeNodeInner(TSNode node, int depth) {
    final start = treeSitter.startByte(node);
    final end = treeSitter.endByte(node);
    final nodeType = treeSitter.nodeTypeString(node);
    final children = treeSitter.allChildrenOf(node).where(_hasContent).toList();
    if (children.isEmpty) {
      return [_NodeRange(startByte: start, endByte: end, nodeType: nodeType)];
    }

    final length = end - start;
    if (depth > maxRecursionDepth || length < minRecursiveChunkBytes) {
      return [_NodeRange(startByte: start, endByte: end, nodeType: nodeType)];
    }

    final groups = <_NodeRange>[];
    var index = 0;
    while (index < children.length) {
      final first = children[index];
      var groupStart = treeSitter.startByte(first);
      var groupEnd = treeSitter.endByte(first);
      var groupType = treeSitter.nodeTypeString(first);
      var groupLength = groupEnd - groupStart;
      index += 1;

      if (groupLength > desiredChunkBytes) {
        groups.addAll(_mergeNodeInner(first, depth + 1));
        continue;
      }

      while (index < children.length) {
        final next = children[index];
        final nextLength =
            treeSitter.endByte(next) - treeSitter.startByte(next);
        if (groupLength + nextLength > desiredChunkBytes) break;
        groupEnd = treeSitter.endByte(next);
        groupType = '$groupType+${treeSitter.nodeTypeString(next)}';
        groupLength += nextLength;
        index += 1;
      }

      groups.add(
        _NodeRange(
          startByte: groupStart,
          endByte: groupEnd,
          nodeType: groupType,
        ),
      );
    }
    return groups;
  }

  List<_NodeRange> _mergeAdjacent(List<_NodeRange> chunks) {
    final merged = <_NodeRange>[];
    var current = chunks.first;
    var currentLength = current.length;
    for (final next in chunks.skip(1)) {
      if (currentLength + next.length > desiredChunkBytes) {
        merged.add(current);
        current = next;
        currentLength = next.length;
        continue;
      }
      current = current.merge(next);
      currentLength += next.length;
    }
    merged.add(current);
    return merged;
  }

  /// Enforce [hardMaxChunkBytes] on the final chunk list. Any chunk that
  /// exceeds the cap is split along line boundaries in the source text.
  List<_NodeRange> _enforceHardCap(List<_NodeRange> chunks, String source) {
    final result = <_NodeRange>[];
    for (final chunk in chunks) {
      if (chunk.length <= hardMaxChunkBytes) {
        result.add(chunk);
      } else {
        result.addAll(_splitByLines(chunk, source));
      }
    }
    return result;
  }

  /// Split a large [_NodeRange] into smaller chunks along line boundaries.
  /// Uses the source text to find newline positions so splits happen at
  /// line boundaries rather than mid-line.
  List<_NodeRange> _splitByLines(_NodeRange range, String source) {
    final result = <_NodeRange>[];
    var currentStart = range.startByte;

    while (currentStart < range.endByte) {
      final remaining = range.endByte - currentStart;
      if (remaining <= hardMaxChunkBytes) {
        // Fits within the cap — emit as-is.
        result.add(_NodeRange(
          startByte: currentStart,
          endByte: range.endByte,
          nodeType: range.nodeType,
        ));
        break;
      }

      // Target end is currentStart + hardMaxChunkBytes, but we want to
      // find the nearest line boundary before that.
      final targetEnd = currentStart + hardMaxChunkBytes;
      final lineEnd = _findLineBoundary(source, currentStart, targetEnd, range.endByte);
      result.add(_NodeRange(
        startByte: currentStart,
        endByte: lineEnd,
        nodeType: range.nodeType,
      ));
      currentStart = lineEnd;
    }
    return result;
  }

  /// Find the nearest newline byte offset at or before [targetEnd],
  /// searching backward from [targetEnd] to [minStart]. If no newline is
  /// found within the search window, returns [targetEnd] (split mid-line
  /// is acceptable as a last resort).
  int _findLineBoundary(String source, int minStart, int targetEnd, int maxEnd) {
    // Clamp to valid range.
    final clampedTarget = targetEnd.clamp(minStart, maxEnd);
    // Search backward for a newline (0x0a). Newline is always a single
    // byte in UTF-8 and cannot appear as a continuation byte, so a
    // byte-level search is safe.
    const maxLookback = 300;
    final searchStart = (clampedTarget - maxLookback).clamp(minStart, maxEnd);
    for (var i = clampedTarget - 1; i >= searchStart; i--) {
      // Convert byte offset to char offset to read the source.
      // For ASCII (including newline), byte offset == char offset.
      // For non-ASCII, we need to be careful — but newline is ASCII.
      if (i < source.length && source.codeUnitAt(_byteToCharOffset(source, i)) == 0x0a) {
        // Return the byte offset of the newline + 1 (start of next line).
        return i + 1;
      }
    }
    // No newline found — split at target.
    return clampedTarget;
  }

  /// Convert a byte offset to a char offset. For ASCII text this is the
  /// identity. For non-ASCII text, we walk the source to find the char
  /// index corresponding to the byte offset.
  static int _byteToCharOffset(String source, int byteOffset) {
    if (byteOffset <= 0) return 0;
    var bytesSeen = 0;
    for (var i = 0; i < source.length; i++) {
      final c = source.codeUnitAt(i);
      int utf8Len;
      if (c < 0x80) {
        utf8Len = 1;
      } else if (c < 0x800) {
        utf8Len = 2;
      } else if (c >= 0xD800 && c <= 0xDBFF) {
        utf8Len = 4;
        i++;
      } else {
        utf8Len = 3;
      }
      if (bytesSeen + utf8Len > byteOffset) return i;
      bytesSeen += utf8Len;
    }
    return source.length;
  }

  CodeChunk _chunkForRange(ParsedSource parsed, _NodeRange range) {
    // Tree-sitter returns UTF-8 byte offsets. We must convert to char
    // offsets before using them as String indices — otherwise files
    // with non-ASCII content (e.g. `→` in a docstring, CJK
    // identifiers) get their chunks sliced at the wrong position.
    // Upstream Python does this conversion in
    // `semble.chunking.core.chunk`; we mirror it here.
    final startChar = _byteOffsetToCharOffset(
      parsed.source,
      range.startByte,
    );
    final endChar = _byteOffsetToCharOffset(
      parsed.source,
      range.endByte,
    );
    final start = startChar.clamp(0, parsed.source.length);
    final end = endChar.clamp(start, parsed.source.length);
    return CodeChunk(
      filePath: parsed.path,
      language: parsed.language,
      startLine: _lineForStart(parsed.source, start),
      endLine: _lineForEnd(parsed.source, end),
      startByte: range.startByte,
      endByte: range.endByte,
      // No trimRight — upstream Python preserves trailing
      // whitespace (including the indentation that closes a
      // multi-line docstring or statement). Stripping it would
      // diverge from the reference output and break BM25 parity.
      content: parsed.source.substring(start, end),
      nodeType: range.nodeType,
      isDefinition: _isDefinitionNode(range.nodeType),
    );
  }

  /// Convert a UTF-8 byte offset (as returned by tree-sitter) into a
  /// Dart String char offset. Mirrors `as_bytes[:byte].decode("utf-8")`
  /// in Python. For pure-ASCII sources the conversion is the identity.
  static int _byteOffsetToCharOffset(String source, int byteOffset) {
    if (byteOffset <= 0) return 0;
    var bytesSeen = 0;
    for (var i = 0; i < source.length; i++) {
      final c = source.codeUnitAt(i);
      // UTF-8 length per Unicode scalar value:
      //   1 byte  for U+0000..U+007F
      //   2 bytes for U+0080..U+07FF
      //   3 bytes for U+0800..U+FFFF (BMP, non-surrogate)
      //   4 bytes for U+10000..U+10FFFF (surrogate pair in UTF-16)
      int utf8Len;
      if (c < 0x80) {
        utf8Len = 1;
      } else if (c < 0x800) {
        utf8Len = 2;
      } else if (c >= 0xD800 && c <= 0xDBFF) {
        // High surrogate: full code point is 4 UTF-8 bytes; skip
        // the matching low surrogate on the next iteration.
        utf8Len = 4;
        i++;
      } else {
        utf8Len = 3;
      }
      if (bytesSeen + utf8Len > byteOffset) return i;
      bytesSeen += utf8Len;
    }
    return source.length;
  }

  /// Count newlines in `source[0:charOffset]` and return the 1-based
  /// line number of the position. Pre-condition: [charOffset] is a
  /// valid char index in [source] (i.e. NOT a byte offset).
  ///
  /// [charOffset] is the position OF the chunk's first char (not
  /// "one past the last char"). The line number is the line that
  /// the chunk starts on — mirroring upstream Python:
  ///   `source[: boundary.start].count("\n") + 1`.
  ///
  /// For example, if `charOffset` is the position of the first
  /// char of line 23 (preceded by 22 newlines), the function
  /// returns 23.
  static int _lineForStart(String source, int charOffset) {
    if (charOffset <= 0) return 1;
    var line = 1;
    final limit = charOffset < source.length
        ? charOffset
        : source.length;
    for (var i = 0; i < limit; i++) {
      if (source.codeUnitAt(i) == 0x0a) line++;
    }
    return line;
  }

  /// Count newlines in `source[0:charOffset]` and return the 1-based
  /// line number of the position. Pre-condition: [charOffset] is a
  /// valid char index in [source] (i.e. NOT a byte offset).
  ///
  /// [charOffset] is the exclusive end (one past the last char of
  /// the chunk). The returned line number is the 1-based line of
  /// the chunk's last char, mirroring upstream Python:
  ///   `source[:end_index].count("\n") + 1` where
  ///   `end_index = boundary.end - 1`.
  ///
  /// This means: we exclude the last char of the chunk from the
  /// newline count. For a chunk that ends with a `\n`, the
  /// newline is the last char, so end_line reports the line of
  /// the content before that trailing newline (e.g. line 2 for
  /// a chunk whose last char is the `\n` at the end of line 2).
  static int _lineForEnd(String source, int charOffset) {
    if (charOffset <= 0) return 1;
    var line = 1;
    // `i < charOffset - 1` mirrors Python's `source[:end_index]`
    // where `end_index = boundary.end - 1`.
    final limit = charOffset - 1;
    if (limit <= 0) return 1;
    for (var i = 0; i < limit; i++) {
      if (source.codeUnitAt(i) == 0x0a) line++;
    }
    return line;
  }

  static bool _isDefinitionNode(String nodeType) {
    return nodeType.contains('class') ||
        nodeType.contains('function') ||
        nodeType.contains('method') ||
        nodeType.contains('constructor') ||
        nodeType.contains('declaration') ||
        nodeType.contains('definition');
  }
}

class _NodeRange {
  final int startByte;
  final int endByte;
  final String nodeType;

  const _NodeRange({
    required this.startByte,
    required this.endByte,
    required this.nodeType,
  });

  int get length => endByte - startByte;

  _NodeRange merge(_NodeRange other) {
    return _NodeRange(
      startByte: startByte,
      endByte: other.endByte,
      nodeType: nodeType == other.nodeType
          ? nodeType
          : '$nodeType+${other.nodeType}',
    );
  }
}
