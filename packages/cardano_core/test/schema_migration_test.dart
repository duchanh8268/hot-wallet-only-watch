import 'package:cardano_core/cardano_core.dart';
import 'package:test/test.dart';

void main() {
  group('SchemaMigrationRunner Tests', () {
    test('Returns data unchanged when existing version matches target version', () {
      final runner = SchemaMigrationRunner();
      final data = {'schemaVersion': 2, 'user': 'alice'};
      final result = runner.migrate(data: data, targetVersion: 2);
      expect(result['schemaVersion'], equals(2));
      expect(result['user'], equals('alice'));
    });

    test('Defaults unversioned legacy data to schemaVersion: 1 and runs migrations sequentially', () {
      final runner = SchemaMigrationRunner();
      runner.registerMigration(1, (data) {
        final accounts = (data['accounts'] as List?)?.cast<String>() ?? [];
        return {
          ...data,
          'accounts': accounts.map((a) => {'id': a, 'name': 'Migrated $a'}).toList(),
        };
      });
      runner.registerMigration(2, (data) {
        return {
          ...data,
          'migratedToV3': true,
        };
      });

      // Legacy v1 data without schemaVersion key
      final legacyData = {
        'network': 'preprod',
        'accounts': ['acc_0', 'acc_1'],
      };

      final migrated = runner.migrate(data: legacyData, targetVersion: 3);

      expect(migrated['schemaVersion'], equals(3));
      expect(migrated['network'], equals('preprod'));
      expect(migrated['migratedToV3'], isTrue);
      expect(
        migrated['accounts'],
        equals([
          {'id': 'acc_0', 'name': 'Migrated acc_0'},
          {'id': 'acc_1', 'name': 'Migrated acc_1'},
        ]),
      );
      // Ensure original data was not modified
      expect(legacyData.containsKey('schemaVersion'), isFalse);
    });

    test('Throws SchemaMigrationException if a migration step is missing and leaves data intact', () {
      final runner = SchemaMigrationRunner();
      runner.registerMigration(1, (data) => {...data, 'v2': true});
      // Missing step 2 -> 3

      final data = {'schemaVersion': 1, 'key': 'value'};

      expect(
        () => runner.migrate(data: data, targetVersion: 3),
        throwsA(isA<SchemaMigrationException>()),
      );
      expect(data['schemaVersion'], equals(1));
    });

    test('Preserves forward-compatible data when schemaVersion is newer than app targetVersion', () {
      final runner = SchemaMigrationRunner();
      final newerData = {'schemaVersion': 5, 'futureFeature': 'enabled'};
      final result = runner.migrate(data: newerData, targetVersion: 2);
      expect(result['schemaVersion'], equals(5));
      expect(result['futureFeature'], equals('enabled'));
    });
  });
}
