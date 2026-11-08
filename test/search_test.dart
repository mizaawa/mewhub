import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/tools/search.dart';

void main() {
  test('parses Bing RSS search results and respects the result limit', () {
    const rss = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel>
<item><title>Flutter &amp; Dart</title><link>https://flutter.dev/</link><description>Build &amp; ship apps.</description><pubDate>Sat, 07 Nov 2026 16:21:00 GMT</pubDate></item>
<item><title>Install Flutter</title><link>https://docs.flutter.dev/install</link><description>Set up &lt;b&gt;Flutter&lt;/b&gt;.</description></item>
<item><title>Ignored result</title><link>https://example.com</link></item>
</channel></rss>''';

    final result = SearchService.parseBingRss(rss, limit: 2);

    expect(result.items, hasLength(2));
    expect(result.items.first.title, 'Flutter & Dart');
    expect(result.items.first.url, 'https://flutter.dev/');
    expect(result.items.first.text, 'Build & ship apps.');
    expect(result.items.first.date, 'Sat, 07 Nov 2026 16:21:00 GMT');
    expect(result.items.last.title, 'Install Flutter');
    expect(result.items.last.text, 'Set up Flutter.');
    expect(SearchService.parseBingRss(rss, limit: 0).items, isEmpty);
  });
}
