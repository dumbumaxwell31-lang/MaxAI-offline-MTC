import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:maxai/core/splash_artwork.dart';
import 'package:maxai/views/splash_view.dart';

void main() {
  testWidgets('splash preserves one preloaded artwork through Home handoff', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1170, 2532);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.runAsync(SplashArtwork.preload);
    final preloadedImage = SplashArtwork.image!;
    expect(preloadedImage.width, 1080);
    expect(preloadedImage.height, 2400);
    expect(SplashArtwork.scale, 3);

    await tester.pumpWidget(const GetMaterialApp(home: SplashView()));
    await tester.pump();

    final imageFinder = find.byType(RawImage);
    final firstFrame = tester.widget<RawImage>(imageFinder);
    final firstFrameBounds = tester.getRect(imageFinder);
    expect(identical(firstFrame.image, preloadedImage), isTrue);
    expect(firstFrame.scale, SplashArtwork.scale);

    await tester.pump(const Duration(seconds: 2));
    final heldFrame = tester.widget<RawImage>(imageFinder);
    expect(identical(heldFrame.image, preloadedImage), isTrue);
    expect(tester.getRect(imageFinder), firstFrameBounds);
    expect(tester.takeException(), isNull);
  });
}
