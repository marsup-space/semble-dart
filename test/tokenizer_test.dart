import 'package:semble_dart/src/tokenizer.dart';
import 'package:test/test.dart';

/// Build a `Map<String, int>` from an ordered token list. The list order
/// is the ID — first token = 0, etc.
Map<String, int> _vocabFromList(List<String> tokens) {
  final v = <String, int>{};
  for (var i = 0; i < tokens.length; i++) {
    v[tokens[i]] = i;
  }
  return v;
}

/// Build a minimal HuggingFace `tokenizer.json` payload from a token
/// list. Defaults to no lowercasing (code-friendly).
Map<String, dynamic> _tokenizerJson(
  List<String> tokens, {
  List<String> added = const [],
  bool doLower = false,
}) {
  final vocab = _vocabFromList(tokens);
  final addedList = <Map<String, dynamic>>[];
  for (final t in added) {
    final id = vocab[t];
    if (id == null) {
      throw StateError('test setup: added token "$t" missing from vocab');
    }
    addedList.add({'content': t, 'id': id});
  }
  return {
    'model': {
      'type': 'WordPiece',
      'unk_token': '[UNK]',
      'vocab': vocab,
    },
    'pre_tokenizer': {
      'type': 'BertPreTokenizer',
      'do_lower_case': doLower,
    },
    'added_tokens': addedList,
  };
}

void main() {
  group('WordPieceTokenizer.fromJson', () {
    test('parses minimal vocab + unk_token', () {
      final t = WordPieceTokenizer.fromJson(_tokenizerJson([
        '[PAD]', '[UNK]', '[CLS]', '[SEP]', 'hello', 'world',
      ]));
      expect(t.vocab['hello'], 4);
      expect(t.vocab['world'], 5);
      expect(t.special.unkToken, '[UNK]');
      expect(t.special.unkId, 1);
      expect(t.special.clsId, 2);
      expect(t.special.sepId, 3);
      expect(t.special.padId, 0);
    });

    test('rejects non-WordPiece model.type', () {
      expect(
        () => WordPieceTokenizer.fromJson({
          'model': {'type': 'BPE', 'vocab': {}, 'unk_token': '[UNK]'},
          'pre_tokenizer': {'type': 'BertPreTokenizer'},
        }),
        throwsArgumentError,
      );
    });

    test('rejects vocab without unk_token', () {
      expect(
        () => WordPieceTokenizer.fromJson({
          'model': {
            'type': 'WordPiece',
            'unk_token': '[UNK]',
            'vocab': {'hello': 0, 'world': 1},
          },
          'pre_tokenizer': {'type': 'BertPreTokenizer'},
        }),
        throwsArgumentError,
      );
    });

    test('respects do_lower_case from pre_tokenizer', () {
      final t = WordPieceTokenizer.fromJson(_tokenizerJson(
        ['[UNK]', 'hello'],
        doLower: true,
      ));
      expect(t.doLowerCase, isTrue);
      // 'Hello' → pretokenize → 'Hello' (case preserved in pretok pass)
      // → WordPiece lookup 'Hello' (not in vocab) → try lowercased via
      // doLowerCase → 'hello' → matches.
      expect(t.tokenize('Hello'), [1]);
    });

    test('preserves case when do_lower_case=false', () {
      final t = WordPieceTokenizer.fromJson(_tokenizerJson(
        ['[UNK]', 'hello'],
      ));
      expect(t.doLowerCase, isFalse);
      expect(t.tokenize('Hello'), [0]); // [UNK]
      expect(t.tokenize('hello'), [1]);
    });

    test('accepts non-int vocab values (cast from double)', () {
      // tokenizer.json values are JSON ints in practice, but the loader
      // shouldn't break if they happen to be floats.
      final t = WordPieceTokenizer.fromJson({
        'model': {
          'type': 'WordPiece',
          'unk_token': '[UNK]',
          'vocab': {'[UNK]': 0.0, 'hello': 1.0},
        },
        'pre_tokenizer': {'type': 'BertPreTokenizer'},
      });
      expect(t.vocab['hello'], 1);
    });
  });

  group('WordPieceTokenizer.tokenize', () {
    late WordPieceTokenizer t;

    setUp(() {
      // Vocabulary designed to exercise:
      // - whole-word matches
      // - subword decomposition (##ing, ##ed, ##s)
      // - punctuation isolation
      // - [UNK] fallback for words with no decomposable path
      t = WordPieceTokenizer.fromJson(_tokenizerJson([
        '[PAD]', '[UNK]', '[CLS]', '[SEP]',
        'hello', 'world', '##ing', '##ed', '##s',
        'un', '##able',
        '.', ',', '!', '?',
      ]));
    });

    test('in-vocab word returns its id', () {
      expect(t.tokenize('hello'), [4]);
    });

    test('multiple words → ids in order', () {
      expect(t.tokenize('hello world'), [4, 5]);
    });

    test('punctuation isolated as own tokens', () {
      expect(t.tokenize('hello, world!'), [4, 13, 5, 15]);
    });

    test('leading/trailing/repeated whitespace collapsed', () {
      expect(t.tokenize('  hello   world  '), [4, 5]);
    });

    test('WordPiece splits unknown suffix into subwords', () {
      // 'helloing' → 'hello' (whole match) + '##ing' (match) → [4, 7]
      expect(t.tokenize('helloing'), [4, 7]);
    });

    test('repeated subwords', () {
      // 'helloingings' → 'hello' + '##ing' + '##ing' + '##s' → [4, 7, 7, 9]
      expect(t.tokenize('helloingings'), [4, 7, 7, 9]);
    });

    test('subwords with ## prefix at non-start position only', () {
      // 'un' matches at start (no prefix), 'able' would need ## → not in
      // vocab → ##able matches → 'unable' splits correctly.
      expect(t.tokenize('unable'), [9, 11]);
    });

    test('unknown word → single [UNK]', () {
      expect(t.tokenize('xyz'), [0]);
    });

    test('partially-decomposable word → single [UNK]', () {
      // 'unabled' → 'un' matches, 'abled' no path → whole word fails →
      // [UNK] (Bert behavior: never emit partial decomposition).
      expect(t.tokenize('unabled'), [0]);
    });

    test('word longer than maxInputCharsPerWord → [UNK]', () {
      // Default maxInputCharsPerWord is 100. 200 'a's triggers the cap.
      final long = 'a' * 200;
      expect(t.tokenize(long), [0]);
    });

    test('empty string → empty ids', () {
      expect(t.tokenize(''), isEmpty);
    });

    test('only whitespace → empty ids', () {
      expect(t.tokenize('   \n\t  '), isEmpty);
    });

    test('only punctuation → ids for each punct', () {
      expect(t.tokenize('!?,.'), [14, 12, 13, 12]);
    });

    test('code-like input with punctuation isolates', () {
      // 'foo(bar)' → 'foo' [UNK], '(' [UNK], 'bar' [UNK], ')' [UNK]
      expect(t.tokenize('foo(bar)'), [0, 0, 0, 0]);
    });

    test('case sensitive tokenization', () {
      expect(t.tokenize('Hello'), [0]); // 'Hello' not in vocab
      expect(t.tokenize('hello'), [4]);
    });

    test('numbers pass through as their own words', () {
      // No '123' in vocab → [UNK].
      expect(t.tokenize('hello 123 world'), [4, 0, 5]);
    });
  });

  group('SpecialTokens', () {
    test('only UNK when CLS/SEP/PAD absent from added_tokens', () {
      final t = WordPieceTokenizer.fromJson(_tokenizerJson(
        ['[UNK]', 'a', 'b'],
      ));
      expect(t.special.unkId, 0);
      expect(t.special.clsToken, isNull);
      expect(t.special.clsId, isNull);
      expect(t.special.sepId, isNull);
      expect(t.special.padId, isNull);
    });

    test('all four specials discovered via added_tokens', () {
      final t = WordPieceTokenizer.fromJson(_tokenizerJson(
        ['[PAD]', '[UNK]', '[CLS]', '[SEP]', 'a'],
        added: ['[PAD]', '[UNK]', '[CLS]', '[SEP]'],
      ));
      expect(t.special.padId, 0);
      expect(t.special.unkId, 1);
      expect(t.special.clsId, 2);
      expect(t.special.sepId, 3);
    });
  });
}