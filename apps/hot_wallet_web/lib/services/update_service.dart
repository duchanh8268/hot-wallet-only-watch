import 'dart:convert';
import 'package:http/http.dart' as http;

class AppVersionInfo {
  final String version;
  final int buildNumber;
  final int schemaVersion;
  final int minCompatibleSchema;
  final String releaseNotes;

  const AppVersionInfo({
    required this.version,
    required this.buildNumber,
    required this.schemaVersion,
    required this.minCompatibleSchema,
    required this.releaseNotes,
  });

  factory AppVersionInfo.fromJson(Map<String, dynamic> json) {
    return AppVersionInfo(
      version: json['version'] as String? ?? '1.0.0',
      buildNumber: (json['buildNumber'] as num?)?.toInt() ?? 1,
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      minCompatibleSchema: (json['minCompatibleSchema'] as num?)?.toInt() ?? 1,
      releaseNotes: json['releaseNotes'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'buildNumber': buildNumber,
        'schemaVersion': schemaVersion,
        'minCompatibleSchema': minCompatibleSchema,
        'releaseNotes': releaseNotes,
      };

  /// Compares with a given current version and build number.
  /// Returns true if this [AppVersionInfo] is strictly newer.
  bool isNewerThan({required String currentVersion, required int currentBuildNumber}) {
    if (buildNumber > currentBuildNumber) return true;
    return _compareSemver(version, currentVersion) > 0;
  }

  static int _compareSemver(String a, String b) {
    final partsA = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final partsB = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final numA = i < partsA.length ? partsA[i] : 0;
      final numB = i < partsB.length ? partsB[i] : 0;
      if (numA != numB) return numA.compareTo(numB);
    }
    return 0;
  }
}

class UpdateCheckService {
  final http.Client client;

  UpdateCheckService({http.Client? client}) : client = client ?? http.Client();

  Future<AppVersionInfo?> fetchLatestVersion({String url = 'version.json'}) async {
    try {
      final response = await client.get(
        Uri.parse(url),
        headers: {'Cache-Control': 'no-cache, no-store, must-revalidate'},
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return AppVersionInfo.fromJson(json);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
