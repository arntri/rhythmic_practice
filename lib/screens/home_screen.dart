import 'package:flutter/material.dart';

import '../app/orientation.dart';
import '../data/practice_repository.dart';
import '../theme.dart';
import 'account_screen.dart';
import 'guide_recording_screen.dart';
import 'help_screen.dart';
import 'history_screen.dart';
import 'metronome_screen.dart';
import 'practice_screen.dart';
import 'progress_screen.dart';
import 'settings_portal.dart';
import '../widgets/slide_to_unlock.dart';

/// The real home screen (UX overhaul): a calm, full-screen lavender canvas whose
/// whole centre is a single "tap to start" target that drops straight into
/// practice. A ⓘ help button sits top-left, and a menu (other destinations +
/// caregiver settings) top-right. First run shows the caregiver instructions.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.repository});

  /// Injectable for tests; defaults to the real repository.
  final PracticeRepository? repository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final PracticeRepository _repo =
      widget.repository ?? PracticeRepository();

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOnboard());
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  // First run only: show the caregiver instructions, then remember we did.
  Future<void> _maybeOnboard() async {
    try {
      final profile = await _repo.getProfile();
      if (profile.onboardingSeen || !mounted) return;
      await Navigator.of(context).push(PortraitPageRoute(
          builder: (_) => const HelpScreen(isOnboarding: true)));
      await _repo.updateProfile(onboardingSeen: true);
    } catch (_) {
      // Onboarding is best-effort; never block the home screen.
    }
  }

  void _startPractice() {
    // Patient practice surface — landscape.
    Navigator.of(context).push(
      LandscapePageRoute(builder: (_) => const PracticeScreen()),
    );
  }

  void _openHelp() {
    Navigator.of(context).push(
      PortraitPageRoute(builder: (_) => const HelpScreen()),
    );
  }

  // Every menu destination is a caregiver page → portrait.
  Future<void> _push(Widget screen) async {
    Navigator.of(context).pop(); // close the menu sheet
    await Navigator.of(context).push(PortraitPageRoute(builder: (_) => screen));
  }

  // Open the guide-recording flow for any active phrases still missing a guide.
  Future<void> _recordGuides() async {
    Navigator.of(context).pop(); // close the menu sheet
    final phrases = await _repo.getPhrasesNeedingGuide();
    if (!mounted) return;
    if (phrases.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Every active word already has a recorded guide.')));
      return;
    }
    await Navigator.of(context).push(PortraitPageRoute(
        builder: (_) => GuideRecordingScreen(phrases: phrases)));
  }

  void _openMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Scroll-controlled + height-capped so it never overflows in landscape.
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.9,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              // The caregiver gate first + prominent: sliding it opens the full
              // caregiver window (settings, phrases, recording, levels, …).
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SlideToUnlock(
                  label: 'Slide to open the caregiver area',
                  onUnlocked: () => _push(const SettingsPortal()),
                ),
              ),
              const Divider(height: 8),
              ListTile(
                leading: const Icon(Icons.mic),
                title: const Text('Record word guides'),
                subtitle: const Text('Record yourself saying each word, slowly'),
                onTap: _recordGuides,
              ),
              ListTile(
                leading: const Icon(Icons.music_note),
                title: const Text('Metronome'),
                onTap: () => _push(const MetronomeScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.family_restroom),
                title: const Text('Progress & family sharing'),
                onTap: () => _push(const ProgressScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.insights),
                title: const Text('History & insights'),
                onTap: () => _push(const HistoryScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.account_circle),
                title: const Text('Account'),
                onTap: () => _push(const AccountScreen()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.calmGradient),
        child: SafeArea(
          child: Stack(
            children: [
              // The whole canvas is the start affordance.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _startPractice,
                  child: Center(
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 1.0, end: 1.06).animate(
                        CurvedAnimation(
                            parent: _pulse, curve: Curves.easeInOut),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 132,
                            height: 132,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.accent,
                            ),
                            child: const Icon(Icons.play_arrow_rounded,
                                size: 84, color: Colors.white),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'Tap to start',
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.bold,
                              color: AppColors.onCalm,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'a practice session',
                            style: TextStyle(
                              fontSize: 18,
                              color: AppColors.onCalm.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Help (top-left).
              Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton.filledTonal(
                    icon: const Icon(Icons.info_outline),
                    tooltip: 'How to use this app',
                    onPressed: _openHelp,
                  ),
                ),
              ),
              // Menu (top-right).
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton.filledTonal(
                    icon: const Icon(Icons.menu),
                    tooltip: 'More',
                    onPressed: _openMenu,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
