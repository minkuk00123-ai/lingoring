import 'package:flutter/material.dart';

/// Toss-style palette: a single confident blue accent on a near-white,
/// low-contrast neutral scale — soft surfaces and shadows carry the
/// hierarchy instead of borders.
class AppColors {
  static const primary = Color(0xFF3182F6);
  static const primaryDark = Color(0xFF1B64DA);
  // Warm "live" indicator for an active mic / call-in-progress state —
  // deliberately outside the blue family so it reads at a glance.
  static const live = Color(0xFFFF5A5F);

  static const bg = Color(0xFFF2F4F6);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF9FAFB);

  static const text1 = Color(0xFF191F28);
  static const text2 = Color(0xFF6B7684);
  static const text3 = Color(0xFFB0B8C1);

  static const border = Color(0xFFE5E8EB);
}
