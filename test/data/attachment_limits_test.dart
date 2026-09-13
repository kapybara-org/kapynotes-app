import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/attachment_limits.dart';

void main() {
  test("an owner's fresh account limit wins over stale space cache", () {
    expect(
      resolveAttachmentMaxBytes(
        accountUserId: 'owner',
        spaceOwnerId: 'owner',
        accountMaxBytes: proAttachmentMaxBytes,
        spaceMaxBytes: freeAttachmentMaxBytes,
      ),
      proAttachmentMaxBytes,
    );
  });

  test("another owner's space limit wins over this account's plan", () {
    expect(
      resolveAttachmentMaxBytes(
        accountUserId: 'member',
        spaceOwnerId: 'owner',
        accountMaxBytes: proAttachmentMaxBytes,
        spaceMaxBytes: freeAttachmentMaxBytes,
      ),
      freeAttachmentMaxBytes,
    );
  });

  test("an old shared-space cache falls back to Free", () {
    expect(
      resolveAttachmentMaxBytes(
        accountUserId: 'member',
        spaceOwnerId: 'owner',
        accountMaxBytes: proAttachmentMaxBytes,
        spaceMaxBytes: null,
      ),
      freeAttachmentMaxBytes,
    );
  });
}
