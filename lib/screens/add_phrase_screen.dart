import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/practice_repository.dart';
import '../practice/syllable_estimate.dart';
import '../services/photo_store.dart';
import 'caregiver_kit.dart';

/// Add a phrase — the words, an optional photo, and an optional question.
///
/// **Nothing assumes English.** The field takes any script, and the syllable
/// read-out is *derived and shown*, never typed: a caregiver should not have to
/// know what a syllable is to use this app, and they certainly should not have
/// to count them.
///
/// The probe question belongs here rather than in a flow of its own, because the
/// person writing the phrase is the person who knows what they would ask to get
/// it. It is optional — without one, that step asks a gentle generic prompt.
class AddPhraseScreen extends StatefulWidget {
  const AddPhraseScreen({super.key, required this.repository});

  final PracticeRepository repository;

  @override
  State<AddPhraseScreen> createState() => _AddPhraseScreenState();
}

class _AddPhraseScreenState extends State<AddPhraseScreen> {
  final _photos = PhotoStore();
  final _text = TextEditingController();
  final _question = TextEditingController();
  String? _photoPath;
  Uint8List? _photoBytes;
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    _question.dispose();
    super.dispose();
  }

  String get _phrase => _text.text.trim();

  /// Two to five syllables is where MIT works best: enough for a contour to
  /// exist, short enough to hold. Shown as guidance, never enforced — a
  /// caregiver knows what their person needs to say better than the app does.
  int get _syllables => _phrase.isEmpty ? 0 : estimateSyllables(_phrase);

  String get _syllableReadout {
    if (_phrase.isEmpty) return 'Type the phrase above';
    final n = _syllables;
    if (!isReliable(_phrase)) {
      // The vowel heuristic cannot read this script. Say so rather than show a
      // confident wrong number — the authored guide will settle it.
      return 'About $n — the recording will confirm it';
    }
    if (n < 2) {
      // Worth saying: a one-syllable target has no contour to intone at all.
      return '$n syllable — there is no melody to sing on one syllable';
    }
    return '$n syllables';
  }

  Future<void> _pickPhoto() async {
    // The store keys a photo by phrase id, and there is no phrase yet — so this
    // uses a temporary id and the real one is set on save.
    final path = await _photos.pickFromGallery(DateTime.now().millisecond);
    if (path == null || !mounted) return;
    final bytes = await _photos.decrypt(path);
    if (!mounted) return;
    setState(() {
      _photoPath = path;
      _photoBytes = bytes;
    });
  }

  Future<void> _save() async {
    if (_phrase.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final id = await widget.repository.addPhrase(_phrase);
      if (_photoPath != null) {
        await widget.repository.setPhoto(id, _photoPath);
      }
      final q = _question.text.trim();
      if (q.isNotEmpty) {
        await widget.repository.setProbeQuestion(id, text: q);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save the phrase: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return CaregiverScaffold(
      eyebrow: 'NEW PHRASE',
      title: 'Add a phrase',
      subtitle: 'Two to five syllables works best.',
      footer: Row(
        children: [
          Expanded(
            child: CaregiverButton(
              label: 'Cancel',
              primary: false,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: CaregiverButton(
              label: 'Save',
              onPressed: _phrase.isEmpty || _saving ? null : _save,
            ),
          ),
        ],
      ),
      children: [
        CaregiverFieldLabel('THE WORDS'),
        const SizedBox(height: 8),
        TextField(
          key: const Key('add_phrase_text'),
          controller: _text,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: CaregiverColors.ink,
          ),
          decoration: InputDecoration(
            hintText: 'Good morning',
            filled: true,
            fillColor: CaregiverColors.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 18,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: CaregiverColors.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: CaregiverColors.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                color: CaregiverColors.accent,
                width: 2,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _syllableReadout,
          key: const Key('add_phrase_syllables'),
          style: const TextStyle(
            fontSize: 14,
            color: CaregiverColors.dim,
          ),
        ),

        const SizedBox(height: 26),
        CaregiverFieldLabel('PHOTO (OPTIONAL)'),
        const SizedBox(height: 8),
        CaregiverCard(
          onTap: _pickPhoto,
          child: Row(
            children: [
              if (_photoBytes != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    _photoBytes!,
                    width: 76,
                    height: 76,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Container(
                  width: 76,
                  height: 76,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: CaregiverColors.faint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.add_photo_alternate_outlined,
                    color: CaregiverColors.dim,
                  ),
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _photoBytes == null ? 'Add a photo' : 'Change the photo',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: CaregiverColors.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'Phrases work fine without one',
                      style: TextStyle(
                        fontSize: 13.5,
                        color: CaregiverColors.dim,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 26),
        CaregiverFieldLabel('QUESTION TO ASK (OPTIONAL)'),
        const SizedBox(height: 8),
        TextField(
          key: const Key('add_phrase_question'),
          controller: _question,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontSize: 17, color: CaregiverColors.ink),
          decoration: InputDecoration(
            hintText: 'What do you say to me in the morning?',
            filled: true,
            fillColor: CaregiverColors.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: CaregiverColors.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: CaregiverColors.line),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const CaregiverNote(
          'At the last step of a session the app asks a question and they answer '
          'with the phrase. Yours will be asked if you write one; otherwise it '
          'asks something general.',
        ),
        const SizedBox(height: 16),
        const CaregiverNote(
          'Guide audio is authored and shipped with the app, not recorded here. '
          'Phrases you add are read by the built-in voice.',
        ),
      ],
    );
  }
}
