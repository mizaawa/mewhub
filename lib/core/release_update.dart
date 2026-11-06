import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

const latestReleaseApi = 'https://api.github.com/repos/mizaawa/mewhub/releases/latest';

class ReleaseUpdate {
  const ReleaseUpdate({required this.version, required this.notes, required this.url});

  final String version;
  final String notes;
  final Uri url;
}

/// Returns a newer published release, or null when offline or already current.
Future<ReleaseUpdate?> checkForReleaseUpdate({http.Client? client, String? currentVersion}) async {
  final ownedClient = client == null;
  client ??= http.Client();
  try {
    final installed = currentVersion ?? (await PackageInfo.fromPlatform()).version;
    final response = await client
        .get(
          Uri.parse(latestReleaseApi),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'MewHub',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map<String, dynamic>) return null;
    final version = (data['tag_name'] as String?)?.trim() ?? '';
    final uri = Uri.tryParse((data['html_url'] as String?) ?? '');
    if (version.isEmpty || uri?.scheme != 'https' || uri?.host != 'github.com') return null;
    if (_compareVersions(version, installed) <= 0) return null;
    return ReleaseUpdate(version: version, notes: (data['body'] as String?)?.trim() ?? '', url: uri!);
  } catch (_) {
    return null;
  } finally {
    if (ownedClient) client.close();
  }
}

int _compareVersions(String a, String b) {
  List<int> parts(String value) =>
      RegExp(
        r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?',
        caseSensitive: false,
      ).firstMatch(value.trim())?.groups([1, 2, 3]).map((part) => int.tryParse(part ?? '') ?? 0).toList() ??
      const [0, 0, 0];
  final first = parts(a);
  final second = parts(b);
  for (var i = 0; i < 3; i++) {
    final difference = first[i].compareTo(second[i]);
    if (difference != 0) return difference;
  }
  return 0;
}
