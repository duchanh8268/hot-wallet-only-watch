import 'dart:convert';

/// Callback to migrate a data map from version `v` to `v + 1`.
typedef MigrationStep = Map<String, dynamic> Function(Map<String, dynamic> data);

/// Thrown when a migration step fails or when encountering an invalid schema state.
class SchemaMigrationException implements Exception {
  final String message;
  final int fromVersion;
  final int targetVersion;
  final dynamic cause;

  const SchemaMigrationException({
    required this.message,
    required this.fromVersion,
    required this.targetVersion,
    this.cause,
  });

  @override
  String toString() =>
      'SchemaMigrationException(from $fromVersion to $targetVersion): $message (cause: $cause)';
}

/// Generic, deterministic schema migration runner ensuring backward compatibility
/// across application versions without losing or resetting user data.
class SchemaMigrationRunner {
  final Map<int, MigrationStep> _migrations = {};

  /// Registers a step migration function from `fromVersion` to `fromVersion + 1`.
  void registerMigration(int fromVersion, MigrationStep step) {
    if (_migrations.containsKey(fromVersion)) {
      throw ArgumentError('Migration for version $fromVersion already registered');
    }
    _migrations[fromVersion] = step;
  }

  /// Migrates [data] from its existing `schemaVersion` (defaulting to 1 if missing)
  /// up to [targetVersion].
  ///
  /// Guarantees:
  /// 1. If [data] is already at or above [targetVersion], no changes are made.
  /// 2. If intermediate migrations exist, they are executed sequentially.
  /// 3. Returns a deep clone of the migrated map with updated `'schemaVersion': targetVersion`.
  Map<String, dynamic> migrate({
    required Map<String, dynamic> data,
    required int targetVersion,
    String versionKey = 'schemaVersion',
  }) {
    final existingVersion = (data[versionKey] as num?)?.toInt() ?? 1;

    if (existingVersion == targetVersion) {
      return Map<String, dynamic>.from(data);
    }

    if (existingVersion > targetVersion) {
      // Data is from a newer version of the app. Ensure forward compatibility
      // by keeping data intact rather than wiping it.
      return Map<String, dynamic>.from(data);
    }

    // Deep clone to ensure immutability of the original input in case of rollback
    var currentData = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;

    for (var v = existingVersion; v < targetVersion; v++) {
      final step = _migrations[v];
      if (step == null) {
        throw SchemaMigrationException(
          message: 'Missing migration step from version $v to ${v + 1}',
          fromVersion: v,
          targetVersion: targetVersion,
        );
      }
      try {
        currentData = step(currentData);
        currentData[versionKey] = v + 1;
      } catch (e) {
        throw SchemaMigrationException(
          message: 'Error executing migration step from $v to ${v + 1}: $e',
          fromVersion: v,
          targetVersion: targetVersion,
          cause: e,
        );
      }
    }

    currentData[versionKey] = targetVersion;
    return currentData;
  }
}
