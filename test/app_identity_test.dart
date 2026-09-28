import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/core/app_identity.dart';
import 'package:maxai/services/local_chat_availability.dart';

void main() {
  test('uses MaxAI as the Flutter application identity', () {
    expect(AppIdentity.name, 'MaxAI');
  });

  test('blocks local chat until a GGUF model is loaded', () {
    expect(
      LocalChatAvailability.canSend(
        inferenceMode: 'local',
        isModelLoaded: false,
      ),
      isFalse,
    );
    expect(
      LocalChatAvailability.canSend(
        inferenceMode: 'local',
        isModelLoaded: true,
      ),
      isTrue,
    );
  });

  test('does not block cloud chat on local model state', () {
    expect(
      LocalChatAvailability.canSend(
        inferenceMode: 'cloud',
        isModelLoaded: false,
      ),
      isTrue,
    );
  });
}
