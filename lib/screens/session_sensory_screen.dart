import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/practice_repository.dart';
import 'caregiver_kit.dart';

/// Session and sensory settings.
///
/// **One tempo, set here and left alone.** There is no per-word dial, and
/// lowering the tempo is not a form of help — MIT intones slowly and stays
/// there. The 40–70 range is a comfort setting; the method's own rate sits
/// inside it.
///
/// The three sensory channels are independent because **any one of them may be
/// the only one a household uses** — a deaf caregiver, a phone permanently on
/// silent, a person who finds vibration unpleasant. The visual beat is the one
/// that must never be the default-off, because it is the fallback for the other
/// two.
class SessionSensoryScreen extends StatefulWidget {
  const SessionSensoryScreen({super.key, required this.repository});

  final PracticeRepository repository;

  @override
  State<SessionSensoryScreen> createState() => _SessionSensoryScreenState();
}

class _SessionSensoryScreenState extends State<SessionSensoryScreen> {
  UserProfile? _profile;
  bool _loading = true;
  String? _error;

  // Live copies, so a control moves under the thumb rather than after a write.
  late int _bpm;
  late int _words;
  late bool _sound;
  late bool _visual;
  late bool _haptic;
  late double _speed;
  late int _silenceMs;
  late TargetDisplay _display;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.repository.getProfile();
      if (!mounted) return;
      setState(() {
        _profile = p;
        _bpm = p.metronomeBpm;
        _words = p.sessionPhraseLimit;
        _sound = p.soundEnabled;
        _visual = p.visualEnabled;
        _haptic = p.hapticEnabled;
        _speed = p.playbackSpeed;
        _silenceMs = p.captureSilenceMs;
        _display = p.targetDisplay;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the settings: $e';
        _loading = false;
      });
    }
  }

  void _save(Future<void> Function() write) {
    write().catchError((Object e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return CaregiverScaffold(
      eyebrow: 'THE SESSION',
      title: 'Session and sensory',
      loading: _loading,
      error: _error,
      children: _profile == null
          ? const []
          : [
              CaregiverFieldLabel('TEMPO'),
              const SizedBox(height: 6),
              CaregiverCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$_bpm bpm',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: CaregiverColors.ink,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    Slider(
                      value: _bpm.toDouble(),
                      min: 40,
                      max: 70,
                      divisions: 30,
                      activeColor: CaregiverColors.accent,
                      onChanged: (v) => setState(() => _bpm = v.round()),
                      onChangeEnd: (v) => _save(
                        () => widget.repository.updateProfile(
                          metronomeBpm: v.round(),
                        ),
                      ),
                    ),
                    const Text(
                      'One tempo for the whole session. Slowing it down is not a '
                      'form of help — this therapy intones slowly and stays there.',
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: CaregiverColors.dim,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 26),
              CaregiverFieldLabel('SESSION LENGTH'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final n in [4, 8, 12, 16])
                    CaregiverChoiceChip(
                      label: '$n words',
                      selected: _words == n,
                      onTap: () {
                        setState(() => _words = n);
                        _save(
                          () => widget.repository.updateProfile(
                            sessionPhraseLimit: n,
                          ),
                        );
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Counted in words, not minutes, because a word is what finishes.',
                style: TextStyle(fontSize: 13.5, color: CaregiverColors.dim),
              ),

              const SizedBox(height: 26),
              CaregiverSection(
                label: 'THE BEAT',
                rows: [
                  CaregiverRow(
                    title: 'Sound',
                    switchValue: _sound,
                    onSwitch: (v) {
                      setState(() => _sound = v);
                      _save(
                        () => widget.repository.updateProfile(soundEnabled: v),
                      );
                    },
                  ),
                  CaregiverRow(
                    title: 'Visual beat',
                    meta: 'The screen pulse',
                    switchValue: _visual,
                    onSwitch: (v) {
                      setState(() => _visual = v);
                      _save(
                        () => widget.repository.updateProfile(visualEnabled: v),
                      );
                    },
                  ),
                  CaregiverRow(
                    title: 'Vibration',
                    switchValue: _haptic,
                    onSwitch: (v) {
                      setState(() => _haptic = v);
                      _save(
                        () => widget.repository.updateProfile(hapticEnabled: v),
                      );
                    },
                  ),
                ],
              ),
              if (!_sound && !_visual && !_haptic)
                const CaregiverBanner(
                  tag: 'NO BEAT',
                  text:
                      'With all three off there is nothing to keep time to, and '
                      'the rhythm is half of this therapy. Turn at least one back on.',
                ),

              const SizedBox(height: 26),
              CaregiverFieldLabel('PLAYBACK SPEED'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final s in [1.0, 0.75, 0.5])
                    CaregiverChoiceChip(
                      label: s == 1.0 ? '1×' : '$s×',
                      selected: _speed == s,
                      onTap: () {
                        setState(() => _speed = s);
                        _save(
                          () =>
                              widget.repository.updateProfile(playbackSpeed: s),
                        );
                      },
                    ),
                ],
              ),

              const SizedBox(height: 26),
              CaregiverFieldLabel('SHOW ON SCREEN'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final d in TargetDisplay.values)
                    CaregiverChoiceChip(
                      label: switch (d) {
                        TargetDisplay.picture => 'Picture',
                        TargetDisplay.word => 'Word',
                        TargetDisplay.both => 'Both',
                      },
                      selected: _display == d,
                      onTap: () {
                        setState(() => _display = d);
                        _save(
                          () =>
                              widget.repository.updateProfile(targetDisplay: d),
                        );
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'The picture is the referent; the written word is optional. Many '
                'people with aphasia cannot read reliably.',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: CaregiverColors.dim,
                ),
              ),

              const SizedBox(height: 26),
              CaregiverFieldLabel('RECORDING WINDOW'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final ms in [3000, 4500, 6000, 8000])
                    CaregiverChoiceChip(
                      label: '${(ms / 1000).toStringAsFixed(ms % 1000 == 0 ? 0 : 1)} s',
                      selected: _silenceMs == ms,
                      onTap: () {
                        setState(() => _silenceMs = ms);
                        _save(
                          () => widget.repository.updateProfile(
                            captureSilenceMs: ms,
                          ),
                        );
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'How long a silence ends the recording. Longer gives more room '
                'to start; shorter keeps the session moving.',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: CaregiverColors.dim,
                ),
              ),
            ],
    );
  }
}
