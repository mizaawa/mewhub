import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/documents.dart';

void main() {
  test('extracts text from a FlateDecode PDF', () async {
    final text = await DocumentExtractor.extract(File('test/fixture_simple.pdf'));
    expect(text, contains('Hello MewHub'));
    expect(text, contains('PDF text'));
    expect(text, contains('Esc ) paren ('));
  });

  test('supported extensions', () {
    expect(DocumentExtractor.isSupported('a.PDF'), isTrue);
    expect(DocumentExtractor.isSupported('main.dart'), isTrue);
    expect(DocumentExtractor.isSupported('photo.heic'), isFalse);
  });
}
