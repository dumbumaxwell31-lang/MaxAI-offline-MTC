# MaxAI

MaxAI is an Android-first Flutter chat application that runs supported GGUF language models locally through `llama_flutter_android` and llama.cpp. It is designed to remain usable without a network connection once its selected model is stored on the device.

## Local Model Flow

At startup MaxAI checks device eligibility, measures total and available RAM plus free storage, chooses one model automatically, and downloads only that file when a connection is available. The model is never chosen through a user-facing picker.

| Device resources | User-facing tier | GGUF model | Quantization | Expected size |
| --- | --- | --- | --- | --- |
| 2 to under 6 GB total RAM, or insufficient Pro headroom | MaxAI Lite | Qwen3 0.6B | Q4_K_M | 484 MB |
| At least 6 GB total RAM, 4.5 GB available RAM, and adequate download storage | MaxAI Pro | Qwen3 4B | Q4_K_M | 2.50 GB |

Downloads use persistent app storage and a temporary file. A file must match its pinned source size and SHA-256 as well as pass the GGUF header check before it is marked ready. Existing verified files are reused on later launches. The app does not attempt local inference until the ready model is loaded.

## Android Build

Requirements: Flutter SDK, Android SDK, JDK 17, and the Android NDK configured by the project.

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Release builds require an existing signing key configured through `android/key.properties`; do not change the signing key for an app already installed on devices.

## Architecture

- Flutter/Dart UI and GetX state management
- `DeviceEligibilityService` validates minimum total RAM and free storage
- `ModelSelectionService` applies the two-tier RAM policy
- `AutomaticModelDownloadService` verifies, downloads, and validates the selected GGUF
- `ModelController` loads the selected validated file into `InferenceService`
- `InferenceService` uses `llama_flutter_android` for Android local inference

The Android application ID remains `com.orailnoor.privatelm` to preserve update compatibility and existing on-device data. The user-visible product name is MaxAI.

## Scope

This repository targets Android only. Non-Android platform configurations are intentionally absent. The local model path contains no LiteRT-LM or Stable Diffusion runtime.

Model download and local inference need physical Android-device validation before claiming device-level support.

## License

MIT. See [LICENSE](LICENSE).
