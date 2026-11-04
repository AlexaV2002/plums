import 'package:client/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('effective controls follow assigned roles and permission changes', () {
    const channels = AppRole(
      id: 'channels',
      name: 'Channels',
      permissions: {'manageChannels': true},
    );
    const bans = AppRole(
      id: 'bans',
      name: 'Bans',
      permissions: {'manageBans': true},
    );
    final both = AppPermissions.fromRoles([channels, bans]);
    expect(both.manageChannels, isTrue);
    expect(both.manageBans, isTrue);
    expect(both.manageRoles, isFalse);

    final afterRemoval = AppPermissions.fromRoles([bans]);
    expect(afterRemoval.manageChannels, isFalse);
    expect(afterRemoval.manageBans, isTrue);

    final updated = AppRole.fromJson({
      'id': 'bans',
      'name': 'Bans',
      'permissions': {'manageBans': false, 'manageRoles': 'false'},
    });
    final afterUpdate = AppPermissions.fromRoles([updated]);
    expect(afterUpdate.manageBans, isFalse);
    expect(afterUpdate.manageRoles, isFalse);
  });
}
