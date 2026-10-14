import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/orientation.dart';
import '../data/models.dart';
import '../data/practice_repository.dart';
import '../services/photo_store.dart';
import 'add_phrase_screen.dart';
import 'caregiver_kit.dart';

/// The phrase library — **content management, and nothing more**.
///
/// With the rung column gone this is purely about the words: whether a real
/// guide recording exists, whether there is a photo, whether there is a question
/// for the answer step, and whether the phrase is in rotation. A phrase has no
/// level of its own, so nothing here ranks one.
///
/// **Two audio states matter now.** The sung clip and the slow-spoken clip the
/// Sprechgesang step plays are separate recordings, and a phrase that reaches
/// Level III without the second one falls back to the built-in voice. So the row
/// says which are missing rather than just flagging the phrase.
class PhraseLibraryScreen extends StatefulWidget {
  const PhraseLibraryScreen({super.key, required this.repository});

  final PracticeRepository repository;

  @override
  State<PhraseLibraryScreen> createState() => _PhraseLibraryScreenState();
}

class _PhraseLibraryScreenState extends State<PhraseLibraryScreen> {
  final _photos = PhotoStore();
  List<PracticePhrase> _phrases = const [];
  final Map<int, Uint8List> _thumbs = {};
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
      final thumbs = <int, Uint8List>{};
      for (final p in phrases) {
        final path = p.photoPath;
        if (path == null) continue;
        final bytes = await _photos.decrypt(path);
        if (bytes != null) thumbs[p.phraseId] = bytes;
      }
      if (!mounted) return;
      setState(() {
        _phrases = phrases;
        _thumbs
          ..clear()
          ..addAll(thumbs);
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

  /// What audio and extras a phrase has, said plainly.
  ///
  /// Named for what is there when everything is, and for what is **missing**
  /// when it isn't — "sung only — spoken clip missing" is actionable in a way
  /// that a tick and a cross are not.
  String _state(PracticePhrase p) {
    final has = <String>[
      if (p.hasRecordedGuide) 'sung',
      if (p.hasSprechgesangClip) 'spoken',
      if (p.probeQuestionText?.trim().isNotEmpty ?? false) 'question',
    ];
    if (has.isEmpty) return 'no audio yet — the built-in voice will read it';
    if (!p.hasSprechgesangClip && p.hasRecordedGuide) {
      return has.join(' · ') == 'sung'
          ? 'sung only — spoken clip missing'
          : '${has.join(' · ')} — spoken clip missing';
    }
    return has.join(' · ');
  }

  final Set<int> _pendingOff = {};

  Future<void> _setActive(PracticePhrase p, bool on) async {
    // Optimistic, so the switch moves under the thumb rather than after a round
    // trip; reconciled by the reload.
    setState(() => on ? _pendingOff.remove(p.phraseId) : _pendingOff.add(p.phraseId));
    await widget.repository.setPhraseActive(p.phraseId, on);
    if (mounted) _load();
  }

  bool _isActive(PracticePhrase p) =>
      _pendingOff.contains(p.phraseId) ? false : p.isActive;

  @override
  Widget build(BuildContext context) {
    final active = _phrases.where(_isActive).length;
    return CaregiverScaffold(
      eyebrow: 'OFTEN',
      title: 'Phrases',
      subtitle: _loading ? null : '$active active of ${_phrases.length}.',
      loading: _loading,
      error: _error,
      footer: CaregiverButton(
        label: 'Add a phrase',
        onPressed: () async {
          await Navigator.of(context).push(
            PortraitPageRoute<void>(
              builder: (_) => AddPhraseScreen(repository: widget.repository),
            ),
          );
          if (mounted) _load();
        },
      ),
      children: [
        CaregiverSection(
          rows: [
            for (final p in _phrases)
              CaregiverRow(
                key: Key('phrase_${p.phraseId}'),
                title: p.phraseText,
                meta: _state(p),
                leading: _Thumb(bytes: _thumbs[p.phraseId]),
                tag: p.isStarter ? const CaregiverTag.held(label: 'bundled') : null,
                // The switch is rotation, not deletion. A phrase switched off is
                // still theirs — it just isn't in this week's practice.
                switchValue: _isActive(p),
                onSwitch: (v) => _setActive(p, v),
              ),
          ],
        ),
        const CaregiverNote(
          'Switching a phrase off takes it out of practice; it is not deleted. '
          'Guide audio is authored and shipped with the app — phrases you add '
          'yourself are read by the built-in voice.',
        ),
      ],
    );
  }
}

/// The photo, or a placeholder patch when there isn't one. A phrase works fine
/// without a photo, so its absence is drawn as an ordinary state rather than a
/// gap to be filled.
class _Thumb extends StatelessWidget {
  const _Thumb({this.bytes});

  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    if (bytes == null) {
      return Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CaregiverColors.faint,
          borderRadius: BorderRadius.circular(11),
        ),
        child: const Icon(
          Icons.text_fields,
          size: 20,
          color: CaregiverColors.dim,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: Image.memory(
        bytes!,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
      ),
    );
  }
}
