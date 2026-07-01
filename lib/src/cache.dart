import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'chunker.dart';

class SembleCache {
  final Directory directory;

  /// Chunker algorithm version. Bump this when the chunker algorithm
  /// changes in a way that produces different chunks for the same source.
  /// This invalidates all existing cache entries so they get re-chunked
  /// with the new algorithm.
  static const int chunkerVersion = 2;

  SembleCache(String path)
    : directory = Directory(p.normalize(p.absolute(path)));

  Future<List<CodeChunk>?> readChunks(String sourcePath) async {
    final source = File(sourcePath);
    if (!source.existsSync()) return null;

    final file = _cacheFile(source.path);
    if (!file.existsSync()) return null;

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final stat = await source.stat();
    if (json['path'] != source.path ||
        json['mtime_ms'] != stat.modified.millisecondsSinceEpoch ||
        json['size'] != stat.size ||
        json['chunker_version'] != chunkerVersion) {
      return null;
    }

    final rawChunks = (json['chunks'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    return [for (final raw in rawChunks) _chunkFromJson(raw)];
  }

  Future<void> writeChunks(String sourcePath, List<CodeChunk> chunks) async {
    final source = File(sourcePath);
    if (!source.existsSync()) return;

    await directory.create(recursive: true);
    final stat = await source.stat();
    final json = <String, Object?>{
      'version': 1,
      'chunker_version': chunkerVersion,
      'path': source.path,
      'mtime_ms': stat.modified.millisecondsSinceEpoch,
      'size': stat.size,
      'chunks': [for (final chunk in chunks) _chunkToJson(chunk)],
    };
    await _cacheFile(source.path).writeAsString(jsonEncode(json));
  }

  Future<void> remove(String sourcePath) async {
    final file = _cacheFile(sourcePath);
    if (file.existsSync()) await file.delete();
  }

  File _cacheFile(String sourcePath) {
    final key = sha256.convert(
      utf8.encode(p.normalize(p.absolute(sourcePath))),
    );
    return File(p.join(directory.path, '$key.json'));
  }
}

Map<String, Object?> _chunkToJson(CodeChunk chunk) => {
  'file_path': chunk.filePath,
  'language': chunk.language,
  'start_line': chunk.startLine,
  'end_line': chunk.endLine,
  'start_byte': chunk.startByte,
  'end_byte': chunk.endByte,
  'content': chunk.content,
  'node_type': chunk.nodeType,
  'is_definition': chunk.isDefinition,
};

CodeChunk _chunkFromJson(Map<String, dynamic> json) {
  return CodeChunk(
    filePath: json['file_path'] as String,
    language: json['language'] as String,
    startLine: (json['start_line'] as num).toInt(),
    endLine: (json['end_line'] as num).toInt(),
    startByte: (json['start_byte'] as num).toInt(),
    endByte: (json['end_byte'] as num).toInt(),
    content: json['content'] as String,
    nodeType: json['node_type'] as String,
    isDefinition: json['is_definition'] as bool,
  );
}
