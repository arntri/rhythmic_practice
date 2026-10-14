import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/practice_repository.dart';
import '../data/starter_library.dart';
import 'caregiver_kit.dart';

/// **Internal. Not shipped.** Checks the authored audio against the MIT targets.
///
/// Every phrase needs **two** clips now: the sung guide, and the slow-spoken
/// Sprechgesang clip the last steps of Level III play. A phrase is only
/// shippable when both are present — with either missing the app falls back to
/// the built-in voice, which works but is not the therapy.
///
/// The acoustic checks (tempo, two pitches a minor third apart, one syllable per
/// beat, stress on the high note, clean tail) are **not implemented here**. This
/// screen reports what the database can actually answer — which clips exist, and
/// which phrases have the metadata the melody is built from — and says plainly
/// that the rest is unchecked. A QA tool that showed green ticks it had not
/// earned would be worse than no QA tool.
class ClipQaScreen extends StatefulWidget {
  const ClipQaScreen({super.key, required this.repository});

  final PracticeRepository repository;

  @override
  State<ClipQaScreen> createState() => _ClipQaScreenState();
}

class _ClipQaScreenState extends State<ClipQaScreen> {
  List<PracticePhrase> _phrases = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final phrases = await widget.repository.getAllPhrases();
      if (!mounted) return;
      setState(() {
        _phrases = phrases;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the phrases: $e';
        _loading = false;
      });
    }
  }

  /// A phrase ships only when both clips exist AND the melody has what it needs
  /// (a confirmed syllable count and a designated high note).
  bool _shippable(PracticePhrase p) =>
      p.hasRecordedGuide &&
      p.hasSprechgesangClip &&
      p.syllableCount >= 2 &&
      p.stressIndex != null;

  @override
  Widget build(BuildContext context) {
    final expected = _phrases.length * 2;
    final present =
        _phrases.where((p) => p.hasRecordedGuide).length +
        _phrases.where((p) => p.hasSprechgesangClip).length;
    final ready = _phrases.where(_shippable).length;

    return CaregiverScaffold(
      eyebrow: 'INTERNAL',
      title: 'Clip QA',
      subtitle: _loading
          ? null
          : '${_phrases.length} phrases · $expected clips expected.',
      loading: _loading,
      error: _error,
      children: [
        CaregiverStats(
          items: [
            ('$ready', 'phrases shippable'),
            ('$present', 'clips present'),
            ('${expected - present}', 'clips missing'),
          ],
        ),
        const SizedBox(height: 16),
        const CaregiverBanner(
          tag: 'NOT A REAL CHECK',
          text:
              'This reports which clips exist, not whether they are correct. '
              'The acoustic targets — 60 bpm, exactly two pitches a minor third '
              'apart, one syllable per beat, stress on the high note, clean '
              'tail — are not verified anywhere yet.',
        ),
        const SizedBox(height: 22),
        CaregiverSection(
          label: 'PER PHRASE',
          rows: [
            for (final p in _phrases) ...[
              CaregiverRow(
                title: '${p.phraseText} · sung',
                meta: p.hasRecordedGuide
                    ? _melodyNote(p)
                    : 'no clip — falls back to the built-in voice',
                tag: p.hasRecordedGuide
                    ? const CaregiverTag.done(label: 'present')
                    : const CaregiverTag.held(label: 'missing'),
              ),
              CaregiverRow(
                title: '${p.phraseText} · spoken',
                meta: p.hasSprechgesangClip
                    ? 'present'
                    : 'no clip — Level III falls back to the built-in voice',
                tag: p.hasSprechgesangClip
                    ? const CaregiverTag.done(label: 'present')
                    : const CaregiverTag.held(label: 'missing'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// What the melody has to work with. Without a confirmed count and a high note
  /// the hum is generated from a guess, or from a single flat tone.
  String _melodyNote(PracticePhrase p) {
    if (p.syllableCount < 2) return 'present — but only one syllable, no contour';
    if (p.stressIndex == null) {
      return 'present — ${p.syllableCount} syllables, no high note designated';
    }
    return 'present — ${p.syllableCount} syllables, '
        'high note on ${p.stressIndex! + 1}';
  }
}

/// **Internal. Not shipped.** Which bundled starters have real audio.
///
/// This screen exists to be alarming, and right now it is: every bundled clip is
/// a synthesized placeholder. A household opening the app today gets phrases
/// that play a tone where a voice should be.
class LibraryManifestScreen extends StatelessWidget {
  const LibraryManifestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return CaregiverScaffold(
      eyebrow: 'INTERNAL',
      title: 'Manifest',
      subtitle:
          '${starterLibrary.length} bundled starters · 0 with real audio.',
      children: [
        const CaregiverBanner(
          tag: 'BLOCKING RELEASE',
          text:
              'Every bundled starter clip is a synthesized placeholder. A new '
              'household opens the app and hears a tone where a voice should be.',
        ),
        const SizedBox(height: 22),
        CaregiverSection(
          label: 'BUNDLED STARTERS',
          rows: [
            for (final s in starterLibrary)
              CaregiverRow(
                title: s.text,
                meta:
                    '${s.syllableCount} '
                    '${s.syllableCount == 1 ? 'syllable' : 'syllables'} · '
                    '${s.assetPath}',
                tag: const CaregiverTag.held(label: 'placeholder'),
              ),
          ],
        ),
        const CaregiverNote(
          'Phrases a caregiver adds themselves are unaffected — they never had '
          'authored audio and are read by the built-in voice by design. This is '
          'only about the clips that ship with the app.',
        ),
      ],
    );
  }
}
