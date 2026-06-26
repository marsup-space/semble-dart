/// WordPiece tokenizer for MinishLab/semble's `potion-code-16M` static
/// embedding model.
///
/// Loads a HuggingFace-format `tokenizer.json` and exposes [tokenize],
/// which produces the integer IDs the embedding model consumes.
///
/// The Potion model's tokenizer is a standard WordPiece variant — same
/// algorithm BERT uses, minus BERT's lowercasing/accent-stripping (which
/// would corrupt code identifiers). Case is preserved.
///
/// Pre-tokenization follows BERT-style rules:
///   - whitespace splits
///   - ASCII punctuation characters are isolated as their own tokens
///
/// WordPiece itself is the standard greedy longest-match-first: given a
/// word, emit `w[start..end]` if it's in the vocab (with `##` prefix for
/// subwords past the start), continue from `end`. If any piece can't be
/// tokenized, the whole word falls back to [SpecialTokens.unkToken].
library;

/// Special tokens discovered in the loaded vocab. Callers use these IDs
/// to wrap a sequence (e.g. prepend `[CLS]`, append `[SEP]`, pad with
/// `[PAD]`) — [tokenize] does NOT add them automatically so callers have
/// full control over the contract with the embedding model.
class SpecialTokens {
  final String unkToken;
  final int unkId;
  final String? clsToken;
  final int? clsId;
  final String? sepToken;
  final int? sepId;
  final String? padToken;
  final int? padId;

  const SpecialTokens({
    required this.unkToken,
    required this.unkId,
    this.clsToken,
    this.clsId,
    this.sepToken,
    this.sepId,
    this.padToken,
    this.padId,
  });
}

/// WordPiece tokenizer.
///
/// Construct via [WordPieceTokenizer.fromJson] with a parsed
/// `tokenizer.json`. The full file is only read by the caller — keeping
/// this class free of `dart:io` makes it usable from isolates and tests
/// without filesystem fixtures.
class WordPieceTokenizer {
  /// token string → id
  final Map<String, int> vocab;

  /// Special token IDs.
  final SpecialTokens special;

  /// Maximum allowed characters per pretokenized word. HuggingFace BERT
  /// uses 100; we inherit the same default — longer words collapse to
  /// [SpecialTokens.unkToken] in a single token.
  final int maxInputCharsPerWord;

  /// Whether to lowercase input before tokenizing. Off by default for
  /// code (case matters in Dart, Python, Go, etc.).
  final bool doLowerCase;

  WordPieceTokenizer._({
    required this.vocab,
    required this.special,
    required this.doLowerCase,
    required this.maxInputCharsPerWord,
  });

  /// Build from a parsed HuggingFace `tokenizer.json`. Only the fields
  /// this tokenizer actually reads are honored; the rest of the schema
  /// (normalizer, decoder, post_processor, ...) is ignored.
  factory WordPieceTokenizer.fromJson(
    Map<String, dynamic> json, {
    int maxInputCharsPerWord = 100,
  }) {
    final model = json['model'] as Map<String, dynamic>?;
    if (model == null) {
      throw ArgumentError('tokenizer.json missing "model" field');
    }
    final modelType = model['type'] as String?;
    if (modelType != 'WordPiece') {
      throw ArgumentError(
        'expected model.type == "WordPiece", got "$modelType"',
      );
    }

    final rawVocab = model['vocab'] as Map<String, dynamic>?;
    if (rawVocab == null) {
      throw ArgumentError('tokenizer.json missing model.vocab');
    }
    final vocab = <String, int>{};
    for (final entry in rawVocab.entries) {
      final v = entry.value;
      vocab[entry.key] = v is int ? v : (v as num).toInt();
    }

    final unkToken = (model['unk_token'] as String?) ?? '[UNK]';
    final unkId = vocab[unkToken];
    if (unkId == null) {
      throw ArgumentError('vocab missing unk_token "$unkToken"');
    }

    final addedTokens = (json['added_tokens'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>() ??
        const [];
    String? cls;
    String? sep;
    String? pad;
    for (final tok in addedTokens) {
      final content = tok['content'] as String? ?? '';
      final id = (tok['id'] as num?)?.toInt();
      if (id == null) continue;
      switch (content) {
        case '[CLS]':
          cls = content;
        case '[SEP]':
          sep = content;
        case '[PAD]':
          pad = content;
        case '[UNK]':
          // Already covered via unkToken above.
          break;
      }
    }

    bool doLower = false;
    final pretok = json['pre_tokenizer'];
    if (pretok is Map<String, dynamic>) {
      final type = pretok['type'] as String?;
      if (type == 'BertPreTokenizer') {
        doLower = pretok['do_lower_case'] as bool? ?? false;
      }
    }

    return WordPieceTokenizer._(
      vocab: vocab,
      special: SpecialTokens(
        unkToken: unkToken,
        unkId: unkId,
        clsToken: cls,
        clsId: cls == null ? null : vocab[cls],
        sepToken: sep,
        sepId: sep == null ? null : vocab[sep],
        padToken: pad,
        padId: pad == null ? null : vocab[pad],
      ),
      doLowerCase: doLower,
      maxInputCharsPerWord: maxInputCharsPerWord,
    );
  }

  /// Tokenize a string into the integer IDs the embedding model expects.
  ///
  /// Returns a flat list of vocab IDs in order. Caller is responsible
  /// for any `[CLS]`/`[SEP]` wrapping, padding, or truncation — this
  /// method only does the pretokenize + WordPiece pass.
  List<int> tokenize(String text) {
    if (doLowerCase) text = text.toLowerCase();
    final ids = <int>[];
    for (final word in _preTokenize(text)) {
      if (word.isEmpty) continue;
      if (word.length > maxInputCharsPerWord) {
        ids.add(special.unkId);
        continue;
      }
      for (final subword in _wordPiece(word)) {
        final id = vocab[subword];
        ids.add(id ?? special.unkId);
      }
    }
    return ids;
  }

  /// BERT-style pretokenizer: split on whitespace, isolate punctuation,
  /// pass through other runes. Preserves case unless [doLowerCase].
  List<String> _preTokenize(String text) {
    final words = <String>[];
    final buf = StringBuffer();
    for (final rune in text.runes) {
      if (_isWhitespace(rune)) {
        if (buf.isNotEmpty) {
          words.add(buf.toString());
          buf.clear();
        }
      } else if (_isPunctuation(rune)) {
        if (buf.isNotEmpty) {
          words.add(buf.toString());
          buf.clear();
        }
        words.add(String.fromCharCode(rune));
      } else {
        buf.writeCharCode(rune);
      }
    }
    if (buf.isNotEmpty) words.add(buf.toString());
    return words;
  }

  /// Greedy longest-match WordPiece: from `start`, find the longest
  /// prefix (or `##`-prefixed suffix) that's in the vocab. Emit it,
  /// continue from `end`. If any piece fails to match, return
  /// `[special.unkToken]` for the whole word.
  List<String> _wordPiece(String word) {
    final chars = word.runes.toList();
    final result = <String>[];
    int start = 0;
    while (start < chars.length) {
      int end = chars.length;
      String? curToken;
      while (start < end) {
        final substr = String.fromCharCodes(chars.sublist(start, end));
        final candidate = start > 0 ? '##$substr' : substr;
        if (vocab.containsKey(candidate)) {
          curToken = candidate;
          break;
        }
        end -= 1;
      }
      if (curToken == null) return [special.unkToken];
      result.add(curToken);
      start = end;
    }
    return result;
  }

  static bool _isWhitespace(int rune) {
    return rune == 0x20 || // space
        rune == 0x09 || // tab
        rune == 0x0a || // LF
        rune == 0x0d || // CR
        rune == 0x0b || // vertical tab
        rune == 0x0c || // form feed
        (rune >= 0x2000 && rune <= 0x200a) || // various Unicode spaces
        rune == 0x2028 || // line separator
        rune == 0x2029; // paragraph separator
  }

  static bool _isPunctuation(int rune) {
    // ASCII punctuation: BERT's set: !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
    if (rune >= 0x21 && rune <= 0x2f) return true;
    if (rune >= 0x3a && rune <= 0x40) return true;
    if (rune >= 0x5b && rune <= 0x60) return true;
    if (rune >= 0x7b && rune <= 0x7e) return true;
    return false;
  }
}