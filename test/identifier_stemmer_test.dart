import 'package:semble_dart/src/identifier_stemmer.dart';
import 'package:test/test.dart';

void main() {
  const stemmer = IdentifierStemmer();

  group('IdentifierStemmer.stems', () {
    test('camelCase splits lower→upper', () {
      expect(stemmer.stems('parseConfig'), ['parse', 'config']);
    });

    test('CamelCase splits lower→upper at word boundary', () {
      // No acronym rule fires (no two-upper-then-lower), so the camel
      // boundary between `g` (lower) and `P` (upper) is the only split.
      expect(stemmer.stems('ConfigParser'), ['config', 'parser']);
    });

    test('acronym rule splits upper-run → upper|word', () {
      // XML|Parser: between L and P, lookahead is Pa (upper+lower).
      expect(stemmer.stems('XMLParser'), ['xml', 'parser']);
    });

    test('acronym followed by lowercase word', () {
      expect(stemmer.stems('ABCDef'), ['abc', 'def']);
    });

    test('standalone acronym stays whole', () {
      // No following lowercase, so no acronym split.
      expect(stemmer.stems('ABC'), ['abc']);
      expect(stemmer.stems('JSON'), ['json']);
    });

    test('snake_case splits on underscores', () {
      expect(stemmer.stems('config_parser'), ['config', 'parser']);
    });

    test('multiple underscores collapsed', () {
      expect(stemmer.stems('__double__underscore__'), ['double', 'underscore']);
    });

    test('leading underscore stripped', () {
      expect(stemmer.stems('_private'), ['private']);
    });

    test('mixed_case splits on underscores then camel', () {
      expect(stemmer.stems('Mixed_Snake_Case'), ['mixed', 'snake', 'case']);
    });

    test('camelCase + snake_case combined', () {
      expect(stemmer.stems('parse_HTTP_request'), ['parse', 'http', 'request']);
    });

    test('camelCase + acronym + snake_case', () {
      // parseJSONConfig → parse|JSON|Config
      // XMLParser → XML|Parser
      expect(stemmer.stems('parseJSONConfig_XMLParser'), [
        'parse',
        'json',
        'config',
        'xml',
        'parser',
      ]);
    });

    test('namespaced identifier splits on ::', () {
      expect(stemmer.stems('Foo::bar'), ['foo', 'bar']);
    });

    test('dotted identifier splits on .', () {
      // 'HTTPRequest' → acronym rule between P and R (lookahead Re,
      // upper+lower) → ['parse', 'http', 'request'].
      expect(stemmer.stems('parse.HTTPRequest'), ['parse', 'http', 'request']);
    });

    test('letter ↔ digit boundaries', () {
      expect(stemmer.stems('getUserById42'), ['get', 'user', 'by', 'id', '42']);
      expect(stemmer.stems('foo123bar'), ['foo', '123', 'bar']);
    });

    test('pure digits preserved as one stem', () {
      expect(stemmer.stems('123'), ['123']);
    });

    test('pure digits + snake_case', () {
      expect(stemmer.stems('foo_123'), ['foo', '123']);
    });

    test('empty input → empty list', () {
      expect(stemmer.stems(''), isEmpty);
    });

    test('pure separators → empty list', () {
      expect(stemmer.stems('___'), isEmpty);
      expect(stemmer.stems('::'), isEmpty);
      expect(stemmer.stems('....'), isEmpty);
    });

    test('single-char identifier preserved', () {
      expect(stemmer.stems('a'), ['a']);
      expect(stemmer.stems('_'), isEmpty); // stripped then empty
    });

    test('ALL_CAPS_SNAKE', () {
      // No acronym boundary (each upper is alone, no upper+lower
      // lookahead), so it splits only on underscores.
      expect(stemmer.stems('FOO_BAR'), ['foo', 'bar']);
    });

    test('leading separator trimmed', () {
      // '__foo' → split on '_+' → ['', 'foo'] → drop empty → ['foo']
      expect(stemmer.stems('__foo'), ['foo']);
    });

    test('trailing separator trimmed', () {
      expect(stemmer.stems('foo__'), ['foo']);
    });

    test('uppercase acronym in middle of camelCase', () {
      // 'getUserID' → camel at t→U (lower→upper) splits → 'get' +
      // 'UserID'. Then 'UserID' → camel at r→I (lower→upper) splits
      // → 'User' + 'ID'. No acronym split in 'ID' (D is end, no
      // lower after). Result: ['get', 'user', 'id'].
      expect(stemmer.stems('getUserID'), ['get', 'user', 'id']);
    });

    test('mixed digits and acronyms', () {
      // HTTP2Request → camel: P→2 (upper→digit) → no match (camel wants
      // lower/digit→upper, opposite). Digit: P→2 (letter→digit) →
      // split between P and 2. So 'HTTP' + '2' + 'Request'. Then
      // acronym in 'Request'? R single upper, no run. Result:
      // ['http', '2', 'request'].
      expect(stemmer.stems('HTTP2Request'), ['http', '2', 'request']);
    });
  });

  group('IdentifierStemmer.tokenizeText upstream parity', () {
    test('preserves compound identifier plus camel parts', () {
      expect(stemmer.tokenizeText('def getHTTPResponse(): pass'), [
        'def',
        'gethttpresponse',
        'get',
        'http',
        'response',
        'pass',
      ]);
    });

    test('preserves snake_case identifier plus parts', () {
      expect(stemmer.tokenizeText('my_func = config_parser'), [
        'my_func',
        'my',
        'func',
        'config_parser',
        'config',
        'parser',
      ]);
    });

    test('matches identifier-like tokens only', () {
      expect(stemmer.tokenizeText('123 + Foo::bar'), ['foo', 'bar']);
    });
  });
}
