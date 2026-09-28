import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/routes.dart';
import '../core/splash_artwork.dart';

class SplashView extends StatefulWidget {
  const SplashView({super.key});

  @override
  State<SplashView> createState() => _SplashViewState();
}

class _SplashViewState extends State<SplashView> {
  Timer? _navigationTimer;

  @override
  void initState() {
    super.initState();
    _navigationTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) Get.offAllNamed(AppRoutes.home);
    });
  }

  @override
  void dispose() {
    _navigationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final artwork = SplashArtwork.image;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1F4D),
      body: SizedBox.expand(
        child: artwork == null
            ? Image.asset(SplashArtwork.assetPath, fit: BoxFit.fill)
            : RawImage(
                image: artwork,
                scale: SplashArtwork.scale,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.high,
              ),
      ),
    );
  }
}
