/// `dart:ffi` bindings to the combined `libcrux_grammars.{so,dylib,dll}`
/// shared library built by `tool/build_native.dart`. The library
/// statically links libtree-sitter runtime + 12 grammar entry points
/// (Dart, Python, JavaScript, TypeScript, TSX, Go, Rust, Java, C++,
/// Ruby, PHP, PHP-only). Each grammar exports a `tree_sitter_<name>()`
/// function that returns a `const TSLanguage *`.
///
/// **Why a C shim layer?** Dart FFI on macOS-arm64 cannot correctly
/// pass 32-byte structs (TSNode) by value across the FFI boundary —
/// values are received as random stack garbage. The shim layer in
/// `native/crux_treesitter.c` wraps every tree-sitter function that
/// takes a TSNode by value with a pointer-taking version. Dart only
/// ever passes pointers, which FFI handles reliably.
///
/// Loading: pass an explicit [path] in production (resolved from
/// `third_party/bin/<target>/libcrux_grammars.<ext>` at startup);
/// pass null in tests/dev to auto-discover from the package root.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// =============================================================================
// FFI typedefs
// =============================================================================

/// Opaque tree-sitter language object.
final class TSLanguageStruct extends Opaque {}

typedef TSLanguagePtr = Pointer<TSLanguageStruct>;

/// Opaque tree-sitter parser.
final class TSParserStruct extends Opaque {}

typedef TSParserPtr = Pointer<TSParserStruct>;

/// Opaque tree-sitter syntax tree.
final class TSTreeStruct extends Opaque {}

typedef TSTreePtr = Pointer<TSTreeStruct>;

/// UTF-8 encoding constant (the only one we use).
const int _tsEncodingUtf8 = 0;

/// `const TSLanguage *tree_sitter_<lang>(void)`.
typedef _TSTreeSitterLangC = Pointer<TSLanguageStruct> Function();
typedef _TSTreeSitterLangDart = Pointer<TSLanguageStruct> Function();

/// `TSParser *ts_parser_new(void)`.
typedef _TSParserNewC = TSParserPtr Function();
typedef _TSParserNewDart = TSParserPtr Function();

/// `void ts_parser_delete(TSParser *)`.
typedef _TSParserDeleteC = Void Function(TSParserPtr);
typedef _TSParserDeleteDart = void Function(TSParserPtr);

/// `bool ts_parser_set_language(TSParser *, const TSLanguage *)`.
typedef _TSParserSetLanguageC = Bool Function(TSParserPtr, TSLanguagePtr);
typedef _TSParserSetLanguageDart = bool Function(TSParserPtr, TSLanguagePtr);

/// `TSTree *ts_parser_parse_string_encoding(TSParser *, const TSTree *,
///   const char *, uint32_t, TSEncoding)`.
typedef _TSParseStringEncodingC =
    TSTreePtr Function(TSParserPtr, TSTreePtr, Pointer<Uint8>, Uint32, Uint32);
typedef _TSParseStringEncodingDart =
    TSTreePtr Function(TSParserPtr, TSTreePtr, Pointer<Uint8>, int, int);

/// `void ts_tree_delete(TSTree *)`.
typedef _TSTreeDeleteC = Void Function(TSTreePtr);
typedef _TSTreeDeleteDart = void Function(TSTreePtr);

/// Tree-sitter's `TSNode` is a 32-byte struct. Dart never copies this
/// value into managed memory; it only passes pointers allocated by the C
/// shim. The layout is mirrored solely so the pointer has a typed target.
final class TSNodePayload extends Struct {
  @Uint32()
  external int context0;
  @Uint32()
  external int context1;
  @Uint32()
  external int context2;
  @Uint32()
  external int context3;
  external Pointer<Void> id;
  external Pointer<TSTreeStruct> tree;
}

/// `TSNode *crux_ts_tree_root_node_alloc(const TSTree *)` — shim
/// returns a pointer to a malloc'd TSNode.
typedef _TSRootNodeC = Pointer<TSNodePayload> Function(TSTreePtr);
typedef _TSRootNodeDart = Pointer<TSNodePayload> Function(TSTreePtr);
typedef _TSRootNodeFreeC = Void Function(Pointer<TSNodePayload>);
typedef _TSRootNodeFreeDart = void Function(Pointer<TSNodePayload>);

/// `uint32_t crux_ts_node_start_byte(const TSNode *)` — shim.
typedef _TSNodeStartByteC = Uint32 Function(Pointer<TSNodePayload>);
typedef _TSNodeStartByteDart = int Function(Pointer<TSNodePayload>);

/// `uint32_t crux_ts_node_end_byte(const TSNode *)` — shim.
typedef _TSNodeEndByteC = Uint32 Function(Pointer<TSNodePayload>);
typedef _TSNodeEndByteDart = int Function(Pointer<TSNodePayload>);

/// `const char *crux_ts_node_type(const TSNode *)` — shim.
typedef _TSNodeTypeC = Pointer<Utf8> Function(Pointer<TSNodePayload>);
typedef _TSNodeTypeDart = Pointer<Utf8> Function(Pointer<TSNodePayload>);

/// `uint32_t crux_ts_node_child_count(const TSNode *)` — shim.
typedef _TSNodeChildCountC = Uint32 Function(Pointer<TSNodePayload>);
typedef _TSNodeChildCountDart = int Function(Pointer<TSNodePayload>);

/// `uint32_t crux_ts_node_named_child_count(const TSNode *)` — shim.
typedef _TSNodeNamedChildCountC = Uint32 Function(Pointer<TSNodePayload>);
typedef _TSNodeNamedChildCountDart = int Function(Pointer<TSNodePayload>);

/// `TSNode crux_ts_node_child(const TSNode *, uint32_t)` — shim
/// dereferences; the returned TSNode is now 32 bytes which we
/// can't return across FFI. Use `crux_ts_node_child_alloc` instead
/// (defined in the shim) that returns a pointer.
typedef _TSNodeChildC =
    Pointer<TSNodePayload> Function(Pointer<TSNodePayload>, Uint32);
typedef _TSNodeChildDart =
    Pointer<TSNodePayload> Function(Pointer<TSNodePayload>, int);

typedef _TSNodeNamedChildC =
    Pointer<TSNodePayload> Function(Pointer<TSNodePayload>, Uint32);
typedef _TSNodeNamedChildDart =
    Pointer<TSNodePayload> Function(Pointer<TSNodePayload>, int);

// =============================================================================
// High-level wrapper
// =============================================================================

/// Loaded `libcrux_grammars` library. Open once, register the
/// languages you care about, parse source into [TSTree]s, walk
/// nodes. Each [TSTree] holds a C-side tree pointer that must be
/// freed via `tree.close()`.
class TreeSitter {
  final DynamicLibrary _lib;
  final _TSParserNewDart _parserNew;
  final _TSParserDeleteDart _parserDelete;
  final _TSParserSetLanguageDart _parserSetLanguage;
  final _TSParseStringEncodingDart _parse;
  final _TSTreeDeleteDart _treeDelete;
  final _TSRootNodeDart _rootNode;
  final _TSRootNodeFreeDart _rootNodeFree;
  final _TSNodeTypeDart _nodeType;
  final _TSNodeStartByteDart _nodeStartByte;
  final _TSNodeEndByteDart _nodeEndByte;
  final _TSNodeChildCountDart _nodeChildCount;
  final _TSNodeNamedChildCountDart _nodeNamedChildCount;
  final _TSNodeChildDart _nodeChild;
  final _TSNodeNamedChildDart _nodeNamedChild;

  final Map<String, TSLanguagePtr> _languages = {};

  TreeSitter._(
    this._lib, {
    required _TSParserNewDart parserNew,
    required _TSParserDeleteDart parserDelete,
    required _TSParserSetLanguageDart parserSetLanguage,
    required _TSParseStringEncodingDart parse,
    required _TSTreeDeleteDart treeDelete,
    required _TSRootNodeDart rootNode,
    required _TSRootNodeFreeDart rootNodeFree,
    required _TSNodeTypeDart nodeType,
    required _TSNodeStartByteDart nodeStartByte,
    required _TSNodeEndByteDart nodeEndByte,
    required _TSNodeChildCountDart nodeChildCount,
    required _TSNodeNamedChildCountDart nodeNamedChildCount,
    required _TSNodeChildDart nodeChild,
    required _TSNodeNamedChildDart nodeNamedChild,
  }) : _parserNew = parserNew,
       _parserDelete = parserDelete,
       _parserSetLanguage = parserSetLanguage,
       _parse = parse,
       _treeDelete = treeDelete,
       _rootNode = rootNode,
       _rootNodeFree = rootNodeFree,
       _nodeType = nodeType,
       _nodeStartByte = nodeStartByte,
       _nodeEndByte = nodeEndByte,
       _nodeChildCount = nodeChildCount,
       _nodeNamedChildCount = nodeNamedChildCount,
       _nodeChild = nodeChild,
       _nodeNamedChild = nodeNamedChild;

  /// Open the library. [path] should be the absolute path to
  /// `libcrux_grammars.<ext>`. If null, falls back to:
  ///   1. `$CRUX_THIRD_PARTY_BIN/libcrux_grammars.<ext>` (env override)
  ///   2. Walk-up to find the package root, then
  ///      `third_party/bin/<target>/libcrux_grammars.<ext>`
  ///   3. DynamicLibrary.process() — symbols already linked into host
  static Future<TreeSitter> load({String? path}) async {
    final lib = path != null
        ? DynamicLibrary.open(path)
        : await _defaultLibrary();
    return TreeSitter._(
      lib,
      parserNew: lib
          .lookup<NativeFunction<_TSParserNewC>>('ts_parser_new')
          .asFunction<_TSParserNewDart>(),
      parserDelete: lib
          .lookup<NativeFunction<_TSParserDeleteC>>('ts_parser_delete')
          .asFunction<_TSParserDeleteDart>(),
      parserSetLanguage: lib
          .lookup<NativeFunction<_TSParserSetLanguageC>>(
            'ts_parser_set_language',
          )
          .asFunction<_TSParserSetLanguageDart>(),
      parse: lib
          .lookup<NativeFunction<_TSParseStringEncodingC>>(
            'ts_parser_parse_string_encoding',
          )
          .asFunction<_TSParseStringEncodingDart>(),
      treeDelete: lib
          .lookup<NativeFunction<_TSTreeDeleteC>>('ts_tree_delete')
          .asFunction<_TSTreeDeleteDart>(),
      rootNode: lib
          .lookup<NativeFunction<_TSRootNodeC>>('crux_ts_tree_root_node_alloc')
          .asFunction<_TSRootNodeDart>(),
      rootNodeFree: lib
          .lookup<NativeFunction<_TSRootNodeFreeC>>(
            'crux_ts_tree_root_node_free',
          )
          .asFunction<_TSRootNodeFreeDart>(),
      nodeType: lib
          .lookup<NativeFunction<_TSNodeTypeC>>('crux_ts_node_type')
          .asFunction<_TSNodeTypeDart>(),
      nodeStartByte: lib
          .lookup<NativeFunction<_TSNodeStartByteC>>('crux_ts_node_start_byte')
          .asFunction<_TSNodeStartByteDart>(),
      nodeEndByte: lib
          .lookup<NativeFunction<_TSNodeEndByteC>>('crux_ts_node_end_byte')
          .asFunction<_TSNodeEndByteDart>(),
      nodeChildCount: lib
          .lookup<NativeFunction<_TSNodeChildCountC>>(
            'crux_ts_node_child_count',
          )
          .asFunction<_TSNodeChildCountDart>(),
      nodeNamedChildCount: lib
          .lookup<NativeFunction<_TSNodeNamedChildCountC>>(
            'crux_ts_node_named_child_count',
          )
          .asFunction<_TSNodeNamedChildCountDart>(),
      nodeChild: lib
          .lookup<NativeFunction<_TSNodeChildC>>('crux_ts_node_child')
          .asFunction<_TSNodeChildDart>(),
      nodeNamedChild: lib
          .lookup<NativeFunction<_TSNodeNamedChildC>>(
            'crux_ts_node_named_child',
          )
          .asFunction<_TSNodeNamedChildDart>(),
    );
  }

  static Future<DynamicLibrary> _defaultLibrary() async {
    final env = Platform.environment['CRUX_THIRD_PARTY_BIN'];
    if (env != null && env.isNotEmpty) {
      return DynamicLibrary.open('$env/libcrux_grammars.${_ext()}');
    }
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      final p =
          '${dir.path}/third_party/bin/${_currentTarget()}'
          '/libcrux_grammars.${_ext()}';
      if (File(p).existsSync()) return DynamicLibrary.open(p);
      dir = dir.parent;
    }
    return DynamicLibrary.process();
  }

  /// Resolve a grammar entry point by name.
  void registerLanguage(String name) {
    if (_languages.containsKey(name)) return;
    final sym = _lib.lookup<NativeFunction<_TSTreeSitterLangC>>(
      'tree_sitter_$name',
    );
    _languages[name] = sym.asFunction<_TSTreeSitterLangDart>()();
  }

  bool hasLanguage(String name) => _languages.containsKey(name);

  /// Parse [source] using the previously-registered [language].
  /// Returns a [TSTree] handle (caller must `tree.close()` to free).
  TSTree parse(String source, {required String language}) {
    final lang = _languages[language];
    if (lang == null) {
      throw StateError(
        'language not registered: $language '
        '(call registerLanguage("$language") first)',
      );
    }
    final bytes = utf8.encode(source);
    final buf = malloc<Uint8>(bytes.length);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      final parser = _parserNew();
      try {
        final ok = _parserSetLanguage(parser, lang);
        if (!ok) {
          throw StateError('tree-sitter rejected language: $language');
        }
        final treePtr = _parse(
          parser,
          nullptr,
          buf,
          bytes.length,
          _tsEncodingUtf8,
        );
        return TSTree._(_treeDelete, _rootNode, _rootNodeFree, treePtr, source);
      } finally {
        _parserDelete(parser);
      }
    } finally {
      malloc.free(buf);
    }
  }

  // ---- TSNode accessors ----

  String nodeTypeString(TSNode node) {
    node._checkValid();
    return _nodeType(node._ptr).cast<Utf8>().toDartString();
  }

  int startByte(TSNode node) {
    node._checkValid();
    return _nodeStartByte(node._ptr);
  }

  int endByte(TSNode node) {
    node._checkValid();
    return _nodeEndByte(node._ptr);
  }

  int childCount(TSNode node) {
    node._checkValid();
    return _nodeChildCount(node._ptr);
  }

  int namedChildCount(TSNode node) {
    node._checkValid();
    return _nodeNamedChildCount(node._ptr);
  }

  /// Returns the i-th named child of [node]. Allocates a fresh
  /// TSNode on the C side (via the child shim) and copies it into
  /// a Dart-side struct value. The allocation is freed before
  /// returning.
  TSNode namedChildAt(TSNode node, int i) {
    node._checkValid();
    return node._owner._adoptNode(_nodeNamedChild(node._ptr, i));
  }

  /// Returns the i-th child (named or anonymous).
  TSNode childAt(TSNode node, int i) {
    node._checkValid();
    return node._owner._adoptNode(_nodeChild(node._ptr, i));
  }

  /// Walk a node's named children.
  List<TSNode> namedChildrenOf(TSNode node) {
    final n = namedChildCount(node);
    return [for (var i = 0; i < n; i++) namedChildAt(node, i)];
  }

  /// Walk all children (named + anonymous).
  List<TSNode> allChildrenOf(TSNode node) {
    final n = childCount(node);
    return [for (var i = 0; i < n; i++) childAt(node, i)];
  }

  /// Release resources. Tree-sitter itself doesn't allocate much
  /// beyond the loaded library, so this is mostly for explicit
  /// lifecycle management. After `close()` the instance should
  /// not be used.
  void close() {
    _languages.clear();
  }
}

/// Handle to a parsed tree. Holds the C-side tree pointer and the
/// source text. `close()` frees the tree.
class TSTree {
  final _TSTreeDeleteDart _delete;
  final _TSRootNodeDart _rootNode;
  final _TSRootNodeFreeDart _rootNodeFree;
  final TSTreePtr _ptr;
  final String source;
  final List<Pointer<TSNodePayload>> _nodes = [];

  bool _closed = false;

  TSTree._(
    this._delete,
    this._rootNode,
    this._rootNodeFree,
    this._ptr,
    this.source,
  );

  bool get isValid => !_closed && _ptr.address != 0;

  /// Root node of the syntax tree. The returned [TSNode] is an owned
  /// handle to a C-side `TSNode*`; it remains valid until this tree is
  /// closed. Dart intentionally never copies the 32-byte struct value.
  TSNode root() {
    _checkValid();
    return _adoptNode(_rootNode(_ptr));
  }

  TSNode _adoptNode(Pointer<TSNodePayload> ptr) {
    _checkValid();
    if (ptr.address == 0) {
      throw StateError('tree-sitter returned a null TSNode pointer');
    }
    _nodes.add(ptr);
    return TSNode._(this, ptr);
  }

  void close() {
    if (!_closed) {
      for (final node in _nodes.reversed) {
        _rootNodeFree(node);
      }
      _nodes.clear();
      _delete(_ptr);
      _closed = true;
    }
  }

  void _checkValid() {
    if (_closed) {
      throw StateError('TSTree has been closed');
    }
  }
}

/// Handle to a C-side `TSNode*` owned by a [TSTree].
class TSNode {
  final TSTree _owner;
  final Pointer<TSNodePayload> _ptr;

  TSNode._(this._owner, this._ptr);

  bool get isValid => !_owner._closed && _ptr.address != 0;

  void _checkValid() {
    if (!isValid) {
      throw StateError('TSNode is no longer valid');
    }
  }
}

// =============================================================================
// Helpers
// =============================================================================

String _ext() {
  if (Platform.isMacOS) return 'dylib';
  if (Platform.isLinux) return 'so';
  if (Platform.isWindows) return 'dll';
  throw UnsupportedError('unsupported platform');
}

String _currentTarget() {
  if (Platform.isMacOS) return 'macos-arm64';
  if (Platform.isLinux) return 'linux-x64';
  if (Platform.isWindows) return 'windows-x64';
  throw UnsupportedError('unsupported target for ${Abi.current()}');
}
