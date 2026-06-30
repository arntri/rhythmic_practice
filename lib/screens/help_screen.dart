import 'package:flutter/material.dart';

import '../theme.dart';

/// Caregiver instructions — shown automatically on first run (onboarding) and
/// reopenable any time from the home screen's ⓘ button (UX overhaul). Covers
/// BOTH how to use the app and how it helps.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key, this.isOnboarding = false});

  /// When true this is the first-run walkthrough: the button reads "Start".
  final bool isOnboarding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.calmGradient),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                children: [
                  Text('Welcome',
                      style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold, color: AppColors.onCalm)),
                  const SizedBox(height: 8),
                  Text(
                    'A calm, rhythm-based speaking practice you do together. '
                    'Here is how a session works.',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: AppColors.onCalm),
                  ),
                  const SizedBox(height: 24),
                  _section(context, '1 · How a session flows', [
                    'Tap “Start” on the home screen to begin.',
                    'First, tap along to the beat once to settle into the rhythm.',
                    'For each word you’ll see the word (or a photo), and usually '
                        'hear a slow spoken model to say along with or after.',
                    'Words come one at a time. Each word has its own level, so '
                        'what it asks of you changes as it gets easier.',
                  ]),
                  _section(context, '2 · The caregiver’s part', [
                    'After each attempt, tap a verdict on the right-hand bar: '
                        'Accept, Unsure, or Not yet.',
                    'Nothing moves on until you tap one — take your time.',
                    'Words climb to a harder level after a few Accepts, and ease '
                        'back after repeated “Not yet”. You can also set the level '
                        'by hand in caregiver settings.',
                  ]),
                  _section(context, '3 · While recording', [
                    'On the higher levels the microphone records the attempt — a '
                        'green glow shows it’s listening.',
                    'Say the word once and pause; recording closes after a short '
                        'silence. Try not to speak twice in that window.',
                    'Audio stays on this device, encrypted. Only anonymous '
                        'progress numbers ever sync (and only if you turn that on).',
                  ]),
                  _section(context, '4 · How it helps', [
                    'It’s based on melodic intonation therapy — practising words '
                        'slowly and on a steady beat.',
                    'It works best on the words you practise, as a companion to '
                        'real speech therapy, not a replacement.',
                    'Every part is optional and gentle — slowing down is support, '
                        'not failure.',
                  ]),
                  const SizedBox(height: 16),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      minimumSize: const Size.fromHeight(56),
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(isOnboarding ? 'Start' : 'Got it'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<String> points) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700, color: AppColors.accent)),
          const SizedBox(height: 8),
          for (final p in points)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 7, right: 10),
                    child: Icon(Icons.circle, size: 7, color: AppColors.accent),
                  ),
                  Expanded(
                    child: Text(p,
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(color: AppColors.onCalm, height: 1.35)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
