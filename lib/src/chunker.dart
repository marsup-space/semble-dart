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
    return [for (final range in ranges) _chunkForRange(parsed, range)];
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

  CodeChunk _chunkForRange(ParsedSource parsed, _NodeRange range) {
    final start = range.startByte.clamp(0, parsed.source.length);
    final end = range.endByte.clamp(start, parsed.source.length);
    return CodeChunk(
      filePath: parsed.path,
      language: parsed.language,
      startLine: _lineForByte(parsed.source, start),
      endLine: _lineForByte(parsed.source, end),
      startByte: start,
      endByte: end,
      content: parsed.source.substring(start, end).trimRight(),
      nodeType: range.nodeType,
      isDefinition: _isDefinitionNode(range.nodeType),
    );
  }

  static int _lineForByte(String source, int byteOffset) {
    var line = 1;
    final limit = byteOffset.clamp(0, source.length);
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
