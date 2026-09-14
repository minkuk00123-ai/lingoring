import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';

import 'core/theme/app_colors.dart';
import 'features/conversation/conversation_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  await dotenv.load(fileName: '.env');
  runApp(const LingoringApp());
}

class LingoringApp extends StatelessWidget {
  const LingoringApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTextTheme = GoogleFonts.gothicA1TextTheme();
    return MaterialApp(
      title: '링고링',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          primary: AppColors.primary,
          surface: AppColors.surface,
        ),
        scaffoldBackgroundColor: AppColors.bg,
        useMaterial3: true,
        fontFamily: baseTextTheme.bodyMedium?.fontFamily,
        textTheme: baseTextTheme.apply(
          bodyColor: AppColors.text1,
          displayColor: AppColors.text1,
        ),
      ),
      home: const ConversationScreen(),
    );
  }
}
