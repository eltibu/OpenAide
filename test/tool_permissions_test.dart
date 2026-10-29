import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/tool_permissions.dart';

void main() {
  test("the chat's choice wins over your default, as on the web", () {
    expect(toolApprovalMode({}, null), 'full');
    expect(
      toolApprovalMode({}, {
        'params': {'tool_approval_mode': 'ask'},
      }),
      'ask',
    );
    expect(
      toolApprovalMode(
        {'tool_approval_mode': 'full'},
        {
          'params': {'tool_approval_mode': 'ask'},
        },
      ),
      'full',
    );
  });
}
