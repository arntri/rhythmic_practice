import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/practice_repository.dart';
import 'screens/home_screen.dart';
import 'services/audio_eviction.dart';
import 'services/sync_service.dart';
import 'services/cloud.dart';
import 'theme.dart';

// main is async because initialising the cloud connection is an async step.
Future<void> main() async {
  // Required before we call any platform services (like SystemChrome) prior to
  // runApp().
  WidgetsFlutterBinding.ensureInitialized();

  // Lock the whole app to landscape, both ways up. The brief calls for a
  // landscape-locked, hands-free layout.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Connect to Supabase if credentials are configured. This never throws — if
  // the cloud is absent or unreachable the app still runs fully locally.
  await Cloud.initialize();

  // Sweep away any audio clips older than 48 hours (brief §6 Privacy). Runs in
  // the background; failures must never block app start.
  AudioEvictionService(PracticeRepository()).evictExpired().catchError((Object e) {
    debugPrint('Audio eviction failed: $e');
    return 0;
  });

  // Opportunistically push any pending data to the cloud. No-op unless the user
  // is signed in and consent is granted; never blocks startup.
  SyncService().pushPending();

  runApp(const RhythmicPracticeApp());
}

class RhythmicPracticeApp extends StatefulWidget {
  const RhythmicPracticeApp({super.key});

  @override
  State<RhythmicPracticeApp> createState() => _RhythmicPracticeAppState();
}

class _RhythmicPracticeAppState extends State<RhythmicPracticeApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground is a good moment to retry any pending sync.
    if (state == AppLifecycleState.resumed) {
      SyncService().pushPending();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rhythmic Practice',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeScreen(),
    );
  }
}
