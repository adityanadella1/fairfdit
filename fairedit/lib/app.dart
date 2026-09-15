import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'providers/edit_provider.dart';
import 'providers/project_provider.dart';
import 'screens/home/home_screen.dart';

class FairEditApp extends StatelessWidget {
  const FairEditApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProjectProvider()),
        // Kept at the app root (not scoped to the editor route) so that
        // bottom sheets/dialogs opened from the editor can read it too.
        ChangeNotifierProvider(create: (_) => EditProvider()),
      ],
      child: MaterialApp(
        title: 'FairEdit',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: const HomeScreen(),
      ),
    );
  }
}
