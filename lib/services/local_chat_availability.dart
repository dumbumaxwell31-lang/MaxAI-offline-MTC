class LocalChatAvailability {
  LocalChatAvailability._();

  static bool canSend({
    required String inferenceMode,
    required bool isModelLoaded,
  }) {
    return inferenceMode != 'local' || isModelLoaded;
  }
}
