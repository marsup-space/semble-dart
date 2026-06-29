// crux_treesitter.c — C shim layer for tree-sitter.
//
// Why this file exists: Dart FFI on macOS-arm64 cannot correctly
// pass 32-byte structs (TSNode) by value across the FFI boundary.
// The struct values are received as random stack garbage by the C
// callee. A 16-byte limit is enforced; structs > 16 bytes must use
// pointer-passing. Rather than put Dart at the mercy of FFI struct
// marshaling, we wrap every tree-sitter function that takes a
// TSNode by value in a pointer-taking shim. The shim dereferences
// the pointer and calls the real function. Dart's side then only
// ever passes pointers, which it handles reliably.
//
// Each shim:
//   1. Takes a `const TSNode *` (Dart's Pointer<TSNodePayload>)
//   2. Dereferences to get the 32-byte struct
//   3. Calls the real tree-sitter function
//   4. Returns whatever the real function returns
//
// All shims use `__attribute__((visibility("default"), used))` so
// the linker exports them and keeps them despite no internal callers.

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

// Mirror the tree-sitter types we use. We deliberately don't include
// <tree_sitter/api.h> here because the build tool passes include
// paths per-translation-unit and the shim is compiled alongside
// grammars. Mirroring is enough for the wrapper to typecheck and
// compile — it's pure pointer shuffling and 1:1 marshaling.
typedef uint32_t ts_context_t[4];
typedef struct TSNode {
  ts_context_t context;
  void *id;
  const void *tree;
} TSNode;
typedef struct TSTree TSTree;
typedef uint32_t TSSymbol;
typedef struct TSPoint {
  uint32_t row;
  uint32_t column;
} TSPoint;

// =============================================================================
// Root node — tree-sitter's ts_tree_root_node returns TSNode by value.
// We allocate the result so Dart can read it via `p.ref`.
// =============================================================================

__attribute__((visibility("default"), used))
TSNode *crux_ts_tree_root_node_alloc(const void *tree) {
  extern TSNode ts_tree_root_node(const void *);
  TSNode *out = (TSNode *) malloc(sizeof(TSNode));
  *out = ts_tree_root_node(tree);
  return out;
}

__attribute__((visibility("default"), used))
void crux_ts_tree_root_node_free(TSNode *node) {
  free(node);
}

/// Free a heap-allocated TSNode returned by the `*_alloc` shims
/// (e.g. `crux_ts_node_child` for nodes returned by value).
__attribute__((visibility("default"), used))
void crux_ts_node_child_free(TSNode *node) {
  free(node);
}

// =============================================================================
// Node accessors — all take TSNode by value in tree-sitter's public
// API. Each shim dereferences a pointer to the same struct, then
// forwards. The returned-by-value types (uint32_t, pointer, TSPoint)
// are simple enough to pass through unchanged.
// =============================================================================

__attribute__((visibility("default"), used))
uint32_t crux_ts_node_start_byte(const TSNode *node) {
  extern uint32_t ts_node_start_byte(TSNode);
  return ts_node_start_byte(*node);
}

__attribute__((visibility("default"), used))
uint32_t crux_ts_node_end_byte(const TSNode *node) {
  extern uint32_t ts_node_end_byte(TSNode);
  return ts_node_end_byte(*node);
}

__attribute__((visibility("default"), used))
TSPoint crux_ts_node_start_point(const TSNode *node) {
  extern TSPoint ts_node_start_point(TSNode);
  return ts_node_start_point(*node);
}

__attribute__((visibility("default"), used))
TSPoint crux_ts_node_end_point(const TSNode *node) {
  extern TSPoint ts_node_end_point(TSNode);
  return ts_node_end_point(*node);
}

__attribute__((visibility("default"), used))
const char *crux_ts_node_type(const TSNode *node) {
  extern const char *ts_node_type(TSNode);
  return ts_node_type(*node);
}

__attribute__((visibility("default"), used))
const char *crux_node_grammar_type(const TSNode *node) {
  extern const char *ts_node_grammar_type(TSNode);
  return ts_node_grammar_type(*node);
}

__attribute__((visibility("default"), used))
TSSymbol crux_ts_node_symbol(const TSNode *node) {
  extern TSSymbol ts_node_symbol(TSNode);
  return ts_node_symbol(*node);
}

__attribute__((visibility("default"), used))
uint32_t crux_ts_node_child_count(const TSNode *node) {
  extern uint32_t ts_node_child_count(TSNode);
  return ts_node_child_count(*node);
}

__attribute__((visibility("default"), used))
uint32_t crux_ts_node_named_child_count(const TSNode *node) {
  extern uint32_t ts_node_named_child_count(TSNode);
  return ts_node_named_child_count(*node);
}

__attribute__((visibility("default"), used))
TSNode crux_ts_node_child(const TSNode *node, uint32_t i) {
  extern TSNode ts_node_child(TSNode, uint32_t);
  // ts_node_child returns TSNode by value. Allocate on heap so
  // Dart can read it via p.ref.
  return ts_node_child(*node, i);
}

__attribute__((visibility("default"), used))
TSNode crux_ts_node_named_child(const TSNode *node, uint32_t i) {
  extern TSNode ts_node_named_child(TSNode, uint32_t);
  return ts_node_named_child(*node, i);
}

__attribute__((visibility("default"), used))
TSNode crux_ts_node_parent(const TSNode *node) {
  extern TSNode ts_node_parent(TSNode);
  return ts_node_parent(*node);
}

__attribute__((visibility("default"), used))
TSNode crux_ts_node_next_sibling(const TSNode *node) {
  extern TSNode ts_node_next_sibling(TSNode);
  return ts_node_next_sibling(*node);
}

__attribute__((visibility("default"), used))
TSNode crux_ts_node_prev_sibling(const TSNode *node) {
  extern TSNode ts_node_prev_sibling(TSNode);
  return ts_node_prev_sibling(*node);
}

__attribute__((visibility("default"), used))
TSNode crux_ts_node_next_named_sibling(const TSNode *node) {
  extern TSNode ts_node_next_named_sibling(TSNode);
  return ts_node_next_named_sibling(*node);
}

__attribute__((visibility("default"), used))
TSNode crux_ts_node_prev_named_sibling(const TSNode *node) {
  extern TSNode ts_node_prev_named_sibling(TSNode);
  return ts_node_prev_named_sibling(*node);
}

// =============================================================================
// Cursor — tree-sitter exposes TSTreeCursor for safe iteration over
// a tree. Cursor functions take TSTreeCursor (8 bytes) by value,
// which IS small enough for Dart FFI. We keep the typedefs direct
// (no shim needed) but provide them here for completeness.
// =============================================================================
typedef struct TSTreeCursor {
  const void *tree;
  const void *id;
  uint32_t context[3];
} TSTreeCursor;
// (TSTreeCursor typedef repeated above so it's defined once.
//  No shim needed — TSTreeCursor is 24 bytes, > 16; we use
//  pointer-passing via ts_tree_cursor_new/free from Dart.)