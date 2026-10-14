import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/practice_repository.dart';
import 'caregiver_kit.dart';

/// Privacy and sharing.
///
/// **The statement first, the toggles under it** — in that order, because the
/// statement is what a family actually wants to read. Recordings stay on the
/// phone. What can leave is counts and timings, and only with consent.
///
/// Both sharing toggles are off by default and stay off until someone turns them
/// on. Nothing here is opt-out.
class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key, required this.repository});

  final PracticeRepository repository;

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  UserProfile? _profile;
  bool _loading = true;
  String? _error;
  late bool _consent;

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
        _consent = p.guardianConsentGranted;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the privacy settings: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return CaregiverScaffold(
      eyebrow: 'SET ONCE',
      title: 'Privacy',
      loading: _loading,
      error: _error,
      children: _profile == null
          ? const []
          : [
              const CaregiverBigStat(
                tag: 'WHAT LEAVES THIS PHONE',
                value: 'Numbers only',
                meta: 'Session length, steps passed, level. Never a recording.',
              ),
              const SizedBox(height: 22),
              CaregiverSection(
                rows: [
                  CaregiverRow(
                    key: const Key('privacy_share'),
                    title: 'Share progress with family',
                    meta: 'Counts and timings only',
                    switchValue: _consent,
                    onSwitch: (v) async {
                      setState(() => _consent = v);
                      await widget.repository.updateProfile(
                        guardianConsentGranted: v,
                      );
                    },
                  ),
                ],
              ),
              const CaregiverNote(
                'Recordings are made so the app can hear the attempt and score '
                'it against the guide, and they are deleted from the phone after '
                '48 hours. They are never uploaded, with sharing on or off.',
              ),
              const SizedBox(height: 16),
              const CaregiverNote(
                'The tap timings and acoustic measurements the app keeps are '
                'numbers derived from a recording, not the recording itself. '
                'They stay on the phone unless you turn sharing on.',
              ),
            ],
    );
  }
}
