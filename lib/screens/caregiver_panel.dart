import 'package:flutter/material.dart';

import '../app/orientation.dart';
import '../data/models.dart';
import '../data/practice_repository.dart';
import '../practice/mit_sequence.dart';
import '../practice/practice_controller.dart';
import 'caregiver_kit.dart';
import 'clip_qa_screen.dart';
import 'help_screen.dart';
import 'history_screen.dart';
import 'in_session_status_screen.dart';
import 'insights_screen.dart';
import 'practice_dose_screen.dart';
import 'practice_level_screen.dart';
import 'phrase_library_screen.dart';
import 'privacy_screen.dart';
import 'progress_summary_screen.dart';
import 'session_sensory_screen.dart';
import 'tapping_tutorial_screen.dart';

/// The caregiver's landing screen — **one panel with sections, not ten screens**.
///
/// The ordering is the point. What gets checked often is at the top and
/// reachable without scrolling: the level the patient is on, what is happening
/// right now, and the phrases. What gets set once — sensory channels, privacy —
/// sits below. Rows carry their current value **in the row**, because that is
/// usually the answer a caregiver came here for; they should not have to open a
/// screen to find out what the level is.
///
/// Reached by the slide-to-unlock, mid-session or from home. When it comes from
/// a session it carries the [controller], which does two things: it lets the
/// "Right now" row exist at all, and it makes the rotation into portrait a real
/// privacy boundary — the session pauses on the spot and the patient's screen
/// goes still.
class CaregiverPanel extends StatefulWidget {
  const CaregiverPanel({
    super.key,
    required this.repository,
    this.controller,
    this.phraseText = const {},
  });

  final PracticeRepository repository;

  /// The live session, when the panel was opened from one.
  final PracticeController? controller;

  /// Phrase text for the live session, for the "Right now" readout.
  final Map<int, String> phraseText;

  @override
  State<CaregiverPanel> createState() => _CaregiverPanelState();
}

class _CaregiverPanelState extends State<CaregiverPanel> {
  UserProfile? _profile;
  int _activePhrases = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The other half of the privacy boundary: nothing runs while a caregiver is
    // reading notes about the person in front of the screen.
    widget.controller?.pauseForCaregiver();
    _load();
  }

  @override
  void dispose() {
    // Back to the patient's screen — but the session does NOT start again here.
    // This only lets the screen offer to carry on; the tap does the rest.
    widget.controller?.caregiverReturned();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.repository.getProfile();
      final active = await widget.repository.getActivePhrases();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _activePhrases = active.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not open the caregiver panel: $e';
        _loading = false;
      });
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(
      PortraitPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) _load(); // values in the rows may have changed
  }

  /// The level row's own answer, so it doesn't have to be opened to be read.
  String _levelMeta(UserProfile p) =>
      '${p.mitLevel.title} · '
      '${p.autoProgressEnabled ? 'advancing automatically' : 'set by hand'}';

  /// What the session is doing, in the three things a caregiver glancing down
  /// mid-session wants: the word, the step, which go.
  String _rightNowMeta(PracticeController c) {
    final word = widget.phraseText[c.currentPhraseId] ?? 'this word';
    if (c.state == PracticeState.sessionComplete) return '$word · finished';
    final steps = stepsFor(c.level);
    final ordinal = steps.indexOf(c.currentStep) + 1;
    return '$word · step $ordinal of ${steps.length} · '
        '${_ordinalGo(c.repNumber)} go';
  }

  static String _ordinalGo(int n) => switch (n) {
    1 => '1st',
    2 => '2nd',
    3 => '3rd',
    _ => '${n}th',
  };

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final controller = widget.controller;
    return CaregiverScaffold(
      eyebrow: 'CAREGIVER',
      title: 'Controls',
      loading: _loading,
      error: _error,
      children: profile == null
          ? const []
          : [
              CaregiverSection(
                label: 'OFTEN',
                rows: [
                  CaregiverRow(
                    key: const Key('panel_level'),
                    title: 'Practice level',
                    meta: _levelMeta(profile),
                    onTap: () => _open(
                      PracticeLevelScreen(repository: widget.repository),
                    ),
                  ),
                  // Only exists mid-session — there is no "right now" from home.
                  if (controller != null) ...[
                    CaregiverRow(
                      key: const Key('panel_rest'),
                      title: 'Take a rest',
                      meta: 'Stop for today, or carry on',
                      onTap: () {
                        // The app never offers this by itself. The person
                        // sitting beside the patient can see whether they are
                        // tiring; an app deciding it from item counts gets it
                        // wrong in both directions.
                        controller.offerRest();
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                  if (controller != null)
                    CaregiverRow(
                      key: const Key('panel_right_now'),
                      title: 'Right now',
                      meta: _rightNowMeta(controller),
                      onTap: () => _open(
                        InSessionStatusScreen(
                          controller: controller,
                          phraseText: widget.phraseText,
                        ),
                      ),
                    ),
                  CaregiverRow(
                    key: const Key('panel_phrases'),
                    title: 'Phrases',
                    meta: '$_activePhrases active',
                    onTap: () => _open(
                      PhraseLibraryScreen(repository: widget.repository),
                    ),
                  ),
                ],
              ),
              CaregiverSection(
                label: 'THE SESSION',
                rows: [
                  CaregiverRow(
                    key: const Key('panel_sensory'),
                    title: 'Session and sensory',
                    meta:
                        '${profile.metronomeBpm} bpm · '
                        '${profile.sessionPhraseLimit} words',
                    onTap: () => _open(
                      SessionSensoryScreen(repository: widget.repository),
                    ),
                  ),
                  CaregiverRow(
                    key: const Key('panel_dose'),
                    title: 'Practice dose',
                    meta: 'Target ${profile.practiceTargetMinutes} min a day',
                    onTap: () => _open(
                      PracticeDoseScreen(repository: widget.repository),
                    ),
                  ),
                  CaregiverRow(
                    key: const Key('panel_progress'),
                    title: 'Progress',
                    onTap: () => _open(
                      ProgressSummaryScreen(repository: widget.repository),
                    ),
                  ),
                  CaregiverRow(
                    key: const Key('panel_history'),
                    title: 'History',
                    meta: 'Per-phrase trends, daily rollup, past sessions',
                    onTap: () =>
                        _open(HistoryScreen(repository: widget.repository)),
                  ),
                ],
              ),
              CaregiverSection(
                label: 'SET ONCE',
                rows: [
                  CaregiverRow(
                    key: const Key('panel_tapping'),
                    title: 'Hand-tapping tutorial',
                    onTap: () => _open(
                      TappingTutorialScreen(bpm: profile.metronomeBpm),
                    ),
                  ),
                  CaregiverRow(
                    key: const Key('panel_help'),
                    title: 'Help',
                    meta: 'How a session works',
                    onTap: () => _open(const HelpScreen()),
                  ),
                  CaregiverRow(
                    key: const Key('panel_privacy'),
                    title: 'Privacy and sharing',
                    meta: profile.guardianConsentGranted
                        ? 'Sharing on'
                        : 'Nothing leaves this phone',
                    onTap: () => _open(
                      PrivacyScreen(repository: widget.repository),
                    ),
                  ),
                  CaregiverRow(
                    key: const Key('panel_insights'),
                    title: 'Insights',
                    meta: 'Experimental',
                    onTap: () => _open(
                      InsightsScreen(repository: widget.repository),
                    ),
                  ),
                ],
              ),
              // Internal tools. Behind demo mode so they are reachable for
              // authoring and QA without being part of what a family sees.
              if (profile.demoModeEnabled)
                CaregiverSection(
                  label: 'INTERNAL — NOT SHIPPED',
                  rows: [
                    CaregiverRow(
                      key: const Key('panel_clip_qa'),
                      title: 'Clip QA',
                      meta: 'Which authored clips exist',
                      onTap: () =>
                          _open(ClipQaScreen(repository: widget.repository)),
                    ),
                    CaregiverRow(
                      key: const Key('panel_manifest'),
                      title: 'Library manifest',
                      meta: 'Bundled starters, real audio vs placeholder',
                      onTap: () => _open(const LibraryManifestScreen()),
                    ),
                  ],
                ),
              if (controller != null)
                const CaregiverNote(
                  'The session is paused while you are in here. It resumes '
                  'where it left off, never mid-word.',
                ),
            ],
    );
  }
}
