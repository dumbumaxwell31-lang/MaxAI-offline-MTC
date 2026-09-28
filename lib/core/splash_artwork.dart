import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class SplashArtwork {
  SplashArtwork._();

  static const assetPath = 'assets/splash/launch_artwork.png';
  static ui.Image? _image;
  static double _scale = 1;

  static ui.Image? get image => _image;
  static double get scale => _scale;

  static Future<void> preload() async {
    final devicePixelRatio =
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final (path, scale) = _assetForDensity(devicePixelRatio);
    final data = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    try {
      final frame = await codec.getNextFrame();
      _image = frame.image;
      _scale = scale;
    } finally {
      codec.dispose();
    }
  }

  static (String, double) _assetForDensity(double density) {
    if (density < 1.25) return (assetPath, 1);
    if (density < 1.75) {
      return ('assets/splash/1.5x/launch_artwork.png', 1.5);
    }
    if (density < 2.5) {
      return ('assets/splash/2.0x/launch_artwork.png', 2);
    }
    if (density < 3.5) {
      return ('assets/splash/3.0x/launch_artwork.png', 3);
    }
    return ('assets/splash/4.0x/launch_artwork.png', 4);
  }
}
