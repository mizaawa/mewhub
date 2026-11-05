import 'dart:convert';

import '../core/net.dart';
import '../core/util.dart';
import '../data/models_misc.dart';

class SearchResultItem {
  SearchResultItem({required this.title, required this.url, this.text = '', this.date});
  final String title;
  final String url;
  final String text;
  final String? date;

  Map<String, dynamic> toJson() => {'title': title, 'url': url, 'text': text, 'publishedDate': ?date};
}

class SearchResult {
  SearchResult(this.items, {this.answer});
  final List<SearchResultItem> items;
  final String? answer;
}

/// Web search backends. All HTTP calls go through [Net] so they are logged
/// and respect proxy / user-agent settings.
class SearchService {
  static Future<SearchResult> search(SearchServiceConfig c, String query, {int? limit}) async {
    final n = limit ?? c.maxResults;
    switch (c.type) {
      case SearchServiceType.tavily:
        final j = asMap(
          await Net.json(
            'POST',
            Uri.parse('https://api.tavily.com/search'),
            headers: {'Authorization': 'Bearer ${c.apiKey}'},
            body: {'query': query, 'max_results': n, 'include_answer': true, 'search_depth': 'basic'},
          ),
        );
        return SearchResult([
          for (final r in asList(j['results']))
            SearchResultItem(
              title: asStr(asMap(r)['title']),
              url: asStr(asMap(r)['url']),
              text: asStr(asMap(r)['content']),
              date: asStrOrNull(asMap(r)['published_date']),
            ),
        ], answer: asStrOrNull(j['answer']));
      case SearchServiceType.exa:
        final j = asMap(
          await Net.json(
            'POST',
            Uri.parse('https://api.exa.ai/search'),
            headers: {'x-api-key': c.apiKey},
            body: {
              'query': query,
              'numResults': n,
              'contents': {
                'text': {'maxCharacters': 1500},
              },
            },
          ),
        );
        return SearchResult([
          for (final r in asList(j['results']))
            SearchResultItem(
              title: asStr(asMap(r)['title']),
              url: asStr(asMap(r)['url']),
              text: asStr(asMap(r)['text']),
              date: asStrOrNull(asMap(r)['publishedDate']),
            ),
        ]);
      case SearchServiceType.brave:
        final j = asMap(
          await Net.json(
            'GET',
            Uri.https('api.search.brave.com', '/res/v1/web/search', {'q': query, 'count': '$n'}),
            headers: {'X-Subscription-Token': c.apiKey, 'Accept': 'application/json'},
          ),
        );
        return SearchResult([
          for (final r in asList(asMap(j['web'])['results']))
            SearchResultItem(
              title: asStr(asMap(r)['title']),
              url: asStr(asMap(r)['url']),
              text: asStr(asMap(r)['description']),
              date: asStrOrNull(asMap(r)['age']),
            ),
        ]);
      case SearchServiceType.serper:
        final j = asMap(
          await Net.json(
            'POST',
            Uri.parse('https://google.serper.dev/search'),
            headers: {'X-API-KEY': c.apiKey},
            body: {'q': query, 'num': n},
          ),
        );
        return SearchResult([
          for (final r in asList(j['organic']))
            SearchResultItem(
              title: asStr(asMap(r)['title']),
              url: asStr(asMap(r)['link']),
              text: asStr(asMap(r)['snippet']),
              date: asStrOrNull(asMap(r)['date']),
            ),
        ], answer: asStrOrNull(asMap(j['answerBox'])['answer']));
      case SearchServiceType.jina:
        final j = asMap(
          await Net.json(
            'GET',
            Uri.parse('https://s.jina.ai/${Uri.encodeComponent(query)}'),
            headers: {'Authorization': 'Bearer ${c.apiKey}', 'Accept': 'application/json', 'X-Retain-Images': 'none'},
          ),
        );
        return SearchResult([
          for (final r in asList(j['data']).take(n))
            SearchResultItem(
              title: asStr(asMap(r)['title']),
              url: asStr(asMap(r)['url']),
              text: truncate(asStr(asMap(r)['content'], asStr(asMap(r)['description'])), 1500),
            ),
        ]);
      case SearchServiceType.zhipu:
        final j = asMap(
          await Net.json(
            'POST',
            Uri.parse('https://open.bigmodel.cn/api/paas/v4/web_search'),
            headers: {'Authorization': 'Bearer ${c.apiKey}'},
            body: {'search_query': query, 'search_engine': 'search_std', 'count': n},
          ),
        );
        return SearchResult([
          for (final r in asList(j['search_result']))
            SearchResultItem(
              title: asStr(asMap(r)['title']),
              url: asStr(asMap(r)['link']),
              text: asStr(asMap(r)['content']),
              date: asStrOrNull(asMap(r)['publish_date']),
            ),
        ]);
      case SearchServiceType.bocha:
        final j = asMap(
          await Net.json(
            'POST',
            Uri.parse('https://api.bochaai.com/v1/web-search'),
            headers: {'Authorization': 'Bearer ${c.apiKey}'},
            body: {'query': query, 'count': n, 'summary': true},
          ),
        );
        final pages = asList(asMap(asMap(asMap(j['data'])['webPages']))['value']);
        return SearchResult([
          for (final r in pages)
            SearchResultItem(
              title: asStr(asMap(r)['name']),
              url: asStr(asMap(r)['url']),
              text: asStr(asMap(r)['summary'], asStr(asMap(r)['snippet'])),
              date: asStrOrNull(asMap(r)['datePublished']),
            ),
        ]);
      case SearchServiceType.perplexity:
        final j = asMap(
          await Net.json(
            'POST',
            Uri.parse('https://api.perplexity.ai/search'),
            headers: {'Authorization': 'Bearer ${c.apiKey}'},
            body: {'query': query, 'max_results': n},
          ),
        );
        return SearchResult([
          for (final r in asList(j['results']))
            SearchResultItem(
              title: asStr(asMap(r)['title']),
              url: asStr(asMap(r)['url']),
              text: asStr(asMap(r)['snippet']),
              date: asStrOrNull(asMap(r)['date']),
            ),
        ]);
      case SearchServiceType.linkup:
        final j = asMap(
          await Net.json(
            'POST',
            Uri.parse('https://api.linkup.so/v1/search'),
            headers: {'Authorization': 'Bearer ${c.apiKey}'},
            body: {'q': query, 'depth': 'standard', 'outputType': 'searchResults'},
          ),
        );
        return SearchResult([
          for (final r in asList(j['results']).take(n))
            SearchResultItem(
              title: asStr(asMap(r)['name']),
              url: asStr(asMap(r)['url']),
              text: asStr(asMap(r)['content']),
            ),
        ]);
      case SearchServiceType.searxng:
        final base = c.url.trim().replaceAll(RegExp(r'/+$'), '');
        if (base.isEmpty) throw ApiException('SearXNG URL is not configured');
        final j = asMap(
          await Net.json('GET', Uri.parse('$base/search').replace(queryParameters: {'q': query, 'format': 'json'})),
        );
        return SearchResult([
          for (final r in asList(j['results']).take(n))
            SearchResultItem(
              title: asStr(asMap(r)['title']),
              url: asStr(asMap(r)['url']),
              text: asStr(asMap(r)['content']),
              date: asStrOrNull(asMap(r)['publishedDate']),
            ),
        ]);
      case SearchServiceType.bing:
        return _bing(query, n);
    }
  }

  /// Keyless fallback: parses Bing's HTML results page.
  static Future<SearchResult> _bing(String query, int n) async {
    final html = await Net.text(
      'GET',
      Uri.https('www.bing.com', '/search', {'q': query, 'setlang': 'en'}),
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
        'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8',
      },
    );
    final items = <SearchResultItem>[];
    final blocks = RegExp(r'<li class="b_algo"[\s\S]*?</li>').allMatches(html);
    for (final b in blocks) {
      final s = b.group(0)!;
      final a = RegExp(r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>').firstMatch(s);
      if (a == null) continue;
      final p = RegExp(r'<p[^>]*>([\s\S]*?)</p>').firstMatch(s);
      items.add(
        SearchResultItem(
          title: _strip(a.group(2)!),
          url: _unescape(a.group(1)!),
          text: p == null ? '' : _strip(p.group(1)!),
        ),
      );
      if (items.length >= n) break;
    }
    return SearchResult(items);
  }

  /// Fetches a page and returns readable text (via Jina Reader when a key is
  /// configured, else a basic HTML-to-text pass).
  static Future<String> scrape(String url, {String? jinaKey}) async {
    if (jinaKey != null && jinaKey.isNotEmpty) {
      return truncate(
        await Net.text(
          'GET',
          Uri.parse('https://r.jina.ai/$url'),
          headers: {'Authorization': 'Bearer $jinaKey', 'X-Return-Format': 'markdown'},
        ),
        20000,
      );
    }
    final html = await Net.text('GET', Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0 MewHub'});
    var body = html.replaceAll(RegExp(r'<(script|style|noscript|svg)[\s\S]*?</\1>', caseSensitive: false), ' ');
    final title = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(body)?.group(1);
    body = body.replaceAll(RegExp(r'<br\s*/?>|</p>|</div>|</h[1-6]>|</li>', caseSensitive: false), '\n');
    final text = _strip(body).replaceAll(RegExp(r'\n\s*\n+'), '\n\n');
    return truncate(jsonEncode({'title': title == null ? '' : _strip(title), 'url': url, 'content': text}), 20000);
  }

  static String _strip(String s) =>
      _unescape(s.replaceAll(RegExp(r'<[^>]+>'), '')).replaceAll(RegExp(r'[ \t]+'), ' ').trim();

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)));
}
