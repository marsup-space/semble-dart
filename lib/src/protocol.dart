/// Wire protocol for the search isolate.
///
/// Messages flow main-isolate → search-isolate (requests) and
/// search-isolate → main-isolate (responses). Each request carries its own
/// [SendPort] for the response, which is what lets the main isolate issue
/// multiple in-flight searches and route each reply back to the right
/// pending future.
///
/// All types in this file are pure data — they must round-trip cleanly
/// through Dart's isolate copy semantics without holding any references
/// to non-transferable objects.
library;

import 'dart:isolate';

// =============================================================================
// Wire types (cross-isolate)
// =============================================================================

/// A single semantic-search result, byte-compatible with the JSON schema
/// Crux's tool layer already consumes.
///
/// JSON field names (`file_path`, `start_line`, `end_line`, `score`,
/// `content`) match upstream MinishLab/semble so existing agent prompts
/// that grep on these names keep working.
class SearchResult {
  final String filePath;
  final int startLine;
  final int endLine;
  final double score;
  final String content;

  const SearchResult({
    required this.filePath,
    required this.startLine,
    required this.endLine,
    required this.score,
    required this.content,
  });

  Map<String, Object?> toJson() => {
        'file_path': filePath,
        'start_line': startLine,
        'end_line': endLine,
        'score': score,
        'content': content,
      };

  @override
  String toString() =>
      'SearchResult($filePath:$startLine-$endLine, score=$score)';
}

// =============================================================================
// Requests (main → search isolate)
// =============================================================================

/// Base type for all messages sent to the search isolate.
///
/// Sealed so the search-isolate's dispatcher can use an exhaustive
/// `switch` and the compiler enforces we handle every case.
sealed class SembleRequest {
  const SembleRequest();
}

/// First message after spawn. Carries the asset paths the search isolate
/// needs to load before it can service any other request.
///
/// Sent exactly once per isolate lifetime. Reply is [ReadyMsg] on success
/// or [ErrorMsg] on failure.
class BootstrapReq extends SembleRequest {
  final String modelPath;
  final String tokenizerPath;
  final String grammarsLibPath;
  final SendPort replyPort;

  const BootstrapReq({
    required this.modelPath,
    required this.tokenizerPath,
    required this.grammarsLibPath,
    required this.replyPort,
  });
}

/// Natural-language or code query over a directory path.
///
/// [replyPort] is per-call so the main isolate can run multiple searches
/// in parallel and route each reply back to the right pending Future.
class SearchReq extends SembleRequest {
  final String query;
  final String path;
  final int topK;
  final SendPort replyPort;

  const SearchReq({
    required this.query,
    required this.path,
    required this.topK,
    required this.replyPort,
  });
}

/// "Find code similar to file:line" — given an anchor in a previously
/// seen chunk, return other semantically similar chunks in the same repo.
class FindRelatedReq extends SembleRequest {
  final String file;
  final int line;
  final String path;
  final int topK;
  final SendPort replyPort;

  const FindRelatedReq({
    required this.file,
    required this.line,
    required this.path,
    required this.topK,
    required this.replyPort,
  });
}

/// Build (or rebuild) the index for [path] ahead of time so the first
/// real search doesn't pay the cold-start cost.
///
/// [replyPort] is nullable: at boot we send fire-and-forget and the main
/// isolate's `SembleWarmup.awaitReady` polls via the [AckMsg] /
/// `Isolate.addErrorListener` lifecycle. For mid-session explicit prewarm,
/// callers pass a replyPort and await.
class PrewarmReq extends SembleRequest {
  final String path;
  final SendPort? replyPort;

  const PrewarmReq({required this.path, this.replyPort});
}

/// Re-index any files changed since the last walk. Always fire-and-forget
/// from the orchestrator's perspective — the user shouldn't wait on
/// `git status` triggering a re-index.
class RefreshReq extends SembleRequest {
  final String path;

  const RefreshReq({required this.path});
}

/// Flush caches, drop in-memory indexes, exit the isolate cleanly.
///
/// Bound by [SembleClient.shutdown]'s timeout — if the search isolate
/// doesn't ack within the deadline, the main isolate gives up and the
/// OS will reap the process on app exit.
class ShutdownReq extends SembleRequest {
  final SendPort replyPort;

  const ShutdownReq({required this.replyPort});
}

// =============================================================================
// Responses (search → main isolate)
// =============================================================================

/// Base type for all messages the search isolate sends back.
sealed class SembleResponse {
  const SembleResponse();
}

/// Reply to [BootstrapReq] — search isolate is loaded and ready to service
/// requests. After receiving this, the main isolate may send [SearchReq] /
/// [FindRelatedReq] / etc.
class ReadyMsg extends SembleResponse {
  const ReadyMsg();
}

/// Reply to [SearchReq].
class SearchResp extends SembleResponse {
  final List<SearchResult> results;

  const SearchResp(this.results);
}

/// Reply to [FindRelatedReq].
class FindRelatedResp extends SembleResponse {
  final List<SearchResult> results;

  const FindRelatedResp(this.results);
}

/// Generic ack for [PrewarmReq] (when it carries a replyPort) and
/// [ShutdownReq].
class AckMsg extends SembleResponse {
  const AckMsg();
}

/// Per-call failure that doesn't terminate the isolate.
///
/// Isolate-level failures (uncaught exception, OOM) are reported via
/// `Isolate.addErrorListener` on the main side and produce a fatal-toast
/// in the TUI; per-call failures land here.
class ErrorMsg extends SembleResponse {
  final String message;
  final String? stack;

  const ErrorMsg(this.message, {this.stack});
}