import 'package:flutter/material.dart';

import '../app/orientation.dart';
import '../data/models.dart';
import '../data/practice_repository.dart';
import '../practice/progression.dart';
import '../services/photo_store.dart';
import '../services/sync_service.dart';
import 'guide_recording_screen.dart';

/// The caregiver settings portal (brief §5). Reached only via slide-to-unlock.
/// Every change is written straight to the local database.
///
/// Phase 1 settings: which phrases are active, tempo, sensory channels, session
/// length — plus the consent toggle (which gates any future cloud upload).
class SettingsPortal extends StatefulWidget {
  const SettingsPortal({super.key, this.repository});

  /// Injectable for tests; defaults to the real repository.
  final PracticeRepository? repository;

  @override
  State<SettingsPortal> createState() => _SettingsPortalState();
}

class _SettingsPortalState extends State<SettingsPortal> {
  late final PracticeRepository _repo =
      widget.repository ?? PracticeRepository();
  final PhotoStore _photos = PhotoStore();

  bool _loading = true;
  UserProfile? _profile;
  List<PracticePhrase> _phrases = [];

  // Local editable copies of the profile settings.
  late int _bpm;
  late bool _visual;
  late bool _sound;
  late bool _haptic;
  late int _sessionLimit;
  late bool _consent;
  late int _captureSilenceMs;
  late bool _autoProgress;
  late TargetDisplay _targetDisplay;
  late double _playbackSpeed;
  // Caregiver "comfort cap" (low-energy days): max rung level, or null = off.
  int? _rungCap;
  // Presenter "demo mode": shows the in-session level picker on the practice
  // screen for live demonstrations.
  late bool _demoMode;
  late bool _soloMode;
  // Which phrase ids are currently active.
  final Set<int> _activeIds = {};
  final _newPhraseController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newPhraseController.dispose();
    super.dispose();
  }

  // Add a custom phrase (any language), then jump straight to recording its
  // guide (therapy addendum §2/§3).
  Future<void> _addPhrase() async {
    final text = _newPhraseController.text.trim();
    if (text.isEmpty) return;
    final id = await _repo.addPhrase(text);
    _newPhraseController.clear();
    await _load();
    if (!mounted) return;
    final phrase = _phrases.firstWhere((p) => p.phraseId == id);
    await _recordGuide(phrase);
  }

  // Ease/regress the progression rung for a phrase (therapy addendum §4).
  Future<void> _setRung(PracticePhrase phrase, Rung rung) async {
    await _repo.setRung(phrase.phraseId, rung);
    if (mounted) await _load();
  }

  // Reset every phrase to the very start of the ladder (R0), clearing tier/tempo
  // — for running a fresh start-to-end pass. Confirms first since it's a wipe.
  Future<void> _resetProgression() async {
    final profile = _profile;
    if (profile == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start over from the beginning?'),
        content: const Text(
          'Every word goes back to R0 (Receive the beat) and its tempo/tier '
          'reset to the start. Recordings, photos and past sessions are kept. '
          'This takes effect on the next practice session.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Start over')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.resetProgression(profile.profileId);
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Progression reset — every word is back at R0.')),
    );
  }

  // Attach or replace a name-card photo from the gallery (therapy addendum §6).
  Future<void> _pickPhoto(PracticePhrase phrase) async {
    final path = await _photos.pickFromGallery(phrase.phraseId);
    if (path == null) return; // cancelled or failed
    await _repo.setPhoto(phrase.phraseId, path);
    if (mounted) await _load();
  }

  // Remove a phrase's photo (turns a name card back into a plain word card).
  Future<void> _removePhoto(PracticePhrase phrase) async {
    await _repo.setPhoto(phrase.phraseId, null);
    if (mounted) await _load();
  }

  // Open the recording flow for one phrase, then refresh so its guide status
  // updates.
  Future<void> _recordGuide(PracticePhrase phrase) async {
    await Navigator.of(context).push(
      PortraitPageRoute(
        builder: (_) =>
            GuideRecordingScreen(phrases: [phrase], repository: _repo),
      ),
    );
    if (mounted) await _load();
  }

  // Set/clear the R7 probe question for a phrase (audit item 11): the question the
  // app plays for the user to answer with the phrase, solo. Cancel leaves it
  // unchanged; Clear (or saving an empty box) removes it (R7 then uses a generic
  // prompt). Text-only for now — a recorded probe clip can be added later.
  Future<void> _editProbeQuestion(PracticePhrase phrase) async {
    final controller =
        TextEditingController(text: phrase.probeQuestionText ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Answer-a-question step (R7)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'The app asks this; “${phrase.phraseText}” is the answer the '
                'person gives on their own.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'e.g. “How are you feeling?”',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), // null → unchanged
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ''), // '' → clear
              child: const Text('Clear')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return; // cancelled — no change
    await _repo.setProbeQuestion(phrase.phraseId,
        text: result.isEmpty ? null : result);
    if (mounted) await _load();
  }

  Future<void> _load() async {
    final profile = await _repo.getProfile();
    final phrases = await _repo.getAllPhrases();
    setState(() {
      _profile = profile;
      _phrases = phrases;
      _bpm = profile.metronomeBpm;
      _visual = profile.visualEnabled;
      _sound = profile.soundEnabled;
      _haptic = profile.hapticEnabled;
      _sessionLimit = profile.sessionPhraseLimit;
      _consent = profile.guardianConsentGranted;
      _captureSilenceMs = profile.captureSilenceMs;
      _autoProgress = profile.autoProgressEnabled;
      _targetDisplay = profile.targetDisplay;
      _playbackSpeed = profile.playbackSpeed;
      _rungCap = profile.sessionRungCap;
      _demoMode = profile.demoModeEnabled;
      _soloMode = profile.soloModeEnabled;
      _activeIds
        ..clear()
        ..addAll(phrases.where((p) => p.isActive).map((p) => p.phraseId));
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Caregiver settings')),
      body: _loading || _profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionTitle('Tempo'),
                Text('$_bpm BPM'),
                // Bounded 40–70 BPM (therapy addendum §5): slowing is a support
                // move; the dial must never reach conversational speed, which
                // would erase the slow one-beat-per-syllable mechanism.
                Slider(
                  value: _bpm.toDouble().clamp(40, 70),
                  min: 40,
                  max: 70,
                  divisions: 30,
                  label: '$_bpm',
                  onChanged: (v) => setState(() => _bpm = v.round()),
                  onChangeEnd: (v) =>
                      _save(() => _repo.updateProfile(metronomeBpm: v.round())),
                ),

                const Divider(height: 32),
                _sectionTitle('Sensory channels'),
                SwitchListTile(
                  title: const Text('Visual'),
                  value: _visual,
                  onChanged: (v) {
                    setState(() => _visual = v);
                    _save(() => _repo.updateProfile(visualEnabled: v));
                  },
                ),
                SwitchListTile(
                  title: const Text('Sound'),
                  value: _sound,
                  onChanged: (v) {
                    setState(() => _sound = v);
                    _save(() => _repo.updateProfile(soundEnabled: v));
                  },
                ),
                SwitchListTile(
                  title: const Text('Haptic'),
                  value: _haptic,
                  onChanged: (v) {
                    setState(() => _haptic = v);
                    _save(() => _repo.updateProfile(hapticEnabled: v));
                  },
                ),

                const Divider(height: 32),
                _sectionTitle('Session length'),
                Text('$_sessionLimit phrases per session'),
                Slider(
                  value: _sessionLimit.toDouble(),
                  min: 1,
                  max: 20,
                  divisions: 19,
                  label: '$_sessionLimit',
                  onChanged: (v) => setState(() => _sessionLimit = v.round()),
                  onChangeEnd: (v) => _save(
                      () => _repo.updateProfile(sessionPhraseLimit: v.round())),
                ),

                const Divider(height: 32),
                _sectionTitle('Recording length'),
                Text('${(_captureSilenceMs / 1000).toStringAsFixed(1)} s'
                    ' (how long to keep recording after the user stops)'),
                Slider(
                  value: _captureSilenceMs.toDouble().clamp(3000, 8000),
                  min: 3000,
                  max: 8000,
                  divisions: 10, // 0.5 s steps
                  label: '${(_captureSilenceMs / 1000).toStringAsFixed(1)} s',
                  onChanged: (v) =>
                      setState(() => _captureSilenceMs = v.round()),
                  onChangeEnd: (v) => _save(
                      () => _repo.updateProfile(captureSilenceMs: v.round())),
                ),

                const Divider(height: 32),
                _sectionTitle('Target display'),
                const Text('She always hears the word spoken. Choose the '
                    'on-screen support (a picture is the easiest to follow):'),
                const SizedBox(height: 8),
                SegmentedButton<TargetDisplay>(
                  segments: const [
                    ButtonSegment(
                        value: TargetDisplay.picture,
                        label: Text('Picture'),
                        icon: Icon(Icons.image)),
                    ButtonSegment(
                        value: TargetDisplay.word,
                        label: Text('Word'),
                        icon: Icon(Icons.title)),
                    ButtonSegment(
                        value: TargetDisplay.both,
                        label: Text('Both'),
                        icon: Icon(Icons.collections)),
                  ],
                  selected: {_targetDisplay},
                  onSelectionChanged: (sel) {
                    setState(() => _targetDisplay = sel.first);
                    _save(() => _repo.updateProfile(targetDisplay: sel.first));
                  },
                ),

                const Divider(height: 32),
                _sectionTitle('Playback speed'),
                const Text('How fast the spoken word comes out. Slower gives '
                    'more time to follow along.'),
                const SizedBox(height: 8),
                SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 1.0, label: Text('1×')),
                    ButtonSegment(value: 0.75, label: Text('0.75×')),
                    ButtonSegment(value: 0.5, label: Text('0.5×')),
                  ],
                  selected: {_playbackSpeed},
                  onSelectionChanged: (sel) {
                    setState(() => _playbackSpeed = sel.first);
                    _save(() => _repo.updateProfile(playbackSpeed: sel.first));
                  },
                ),

                const Divider(height: 32),
                _sectionTitle('Progression'),
                SwitchListTile(
                  title: const Text('Move levels automatically'),
                  subtitle: const Text(
                    'When on, a phrase steps up after consistent passes and '
                    'eases back after repeated misses. You can still set any '
                    "phrase's level by hand below at any time.",
                  ),
                  value: _autoProgress,
                  onChanged: (v) {
                    setState(() => _autoProgress = v);
                    _save(() => _repo.updateProfile(autoProgressEnabled: v));
                  },
                ),
                // Comfort cap (low-energy days): hold the level steady so the app
                // never pushes harder than the chosen rung. Only limits moving up
                // — it never drops a phrase already above the cap.
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Comfort cap for low-energy days'),
                  subtitle: const Text(
                    "Don't move any phrase past this level. Use it on a tired "
                    'day; set it back to Off when ready to push on. It never '
                    'lowers a phrase already above the cap.',
                  ),
                  trailing: DropdownButton<int?>(
                    value: _rungCap,
                    hint: const Text('Off'),
                    onChanged: _autoProgress
                        ? (v) {
                            setState(() => _rungCap = v);
                            _save(() =>
                                _repo.updateProfile(sessionRungCap: v));
                          }
                        : null,
                    items: <DropdownMenuItem<int?>>[
                      const DropdownMenuItem(value: null, child: Text('Off')),
                      for (final rung in Rung.values)
                        DropdownMenuItem(
                          value: rung.level,
                          child: Text('${rung.code} · ${rung.title}'),
                        ),
                    ],
                  ),
                ),

                const Divider(height: 32),
                _sectionTitle('Demonstration'),
                SwitchListTile(
                  title: const Text('Demo mode (level picker in session)'),
                  subtitle: const Text(
                    'For showing the app live. Adds a level picker on the '
                    "practice screen so you can jump the current word to any "
                    'stage (R0–R6) on demand. The change lasts only for that '
                    "session — it never alters a phrase's saved progress. Leave "
                    'off for normal therapy.',
                  ),
                  value: _demoMode,
                  onChanged: (v) {
                    setState(() => _demoMode = v);
                    _save(() => _repo.updateProfile(demoModeEnabled: v));
                  },
                ),

                const Divider(height: 32),
                _sectionTitle('Experimental'),
                SwitchListTile(
                  title: const Text('Solo practice (experimental)'),
                  subtitle: const Text(
                    'Lets well-mastered words be practised solo, with the app '
                    'giving light feedback. Still experimental: even when on, '
                    'you confirm every verdict — the app never changes levels on '
                    'its own. See Insights in History for what it would do.',
                  ),
                  value: _soloMode,
                  onChanged: (v) {
                    setState(() => _soloMode = v);
                    _save(() => _repo.updateProfile(soloModeEnabled: v));
                  },
                ),

                const Divider(height: 32),
                _sectionTitle('Phrases'),
                // Add a custom phrase (any language), then record its guide.
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newPhraseController,
                        decoration: const InputDecoration(
                          labelText: 'New phrase (any language)',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _addPhrase(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _addPhrase,
                      child: const Text('Add'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                for (final phrase in _phrases)
                  CheckboxListTile(
                    isThreeLine: true,
                    title: Text(phrase.phraseText),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(phrase.hasRecordedGuide
                            ? 'Guide recorded'
                            : 'No guide yet — tap the mic to record'),
                        _rungControl(phrase),
                        _probeControl(phrase),
                      ],
                    ),
                    value: _activeIds.contains(phrase.phraseId),
                    secondary: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Name-card photo (therapy addendum §6): add when none,
                        // else a menu to change or remove it.
                        if (phrase.hasPhoto)
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.image, color: Colors.blue),
                            tooltip: 'Photo',
                            onSelected: (v) => v == 'change'
                                ? _pickPhoto(phrase)
                                : _removePhoto(phrase),
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'change', child: Text('Change photo')),
                              PopupMenuItem(
                                  value: 'remove', child: Text('Remove photo')),
                            ],
                          )
                        else
                          IconButton(
                            icon: const Icon(Icons.add_photo_alternate_outlined),
                            tooltip: 'Add photo (name card)',
                            onPressed: () => _pickPhoto(phrase),
                          ),
                        IconButton(
                          icon: Icon(
                            phrase.hasRecordedGuide ? Icons.mic : Icons.mic_none,
                            color: phrase.hasRecordedGuide ? Colors.green : null,
                          ),
                          tooltip: phrase.hasRecordedGuide
                              ? 'Re-record guide'
                              : 'Record guide',
                          onPressed: () => _recordGuide(phrase),
                        ),
                      ],
                    ),
                    onChanged: (on) {
                      setState(() {
                        if (on == true) {
                          _activeIds.add(phrase.phraseId);
                        } else {
                          _activeIds.remove(phrase.phraseId);
                        }
                      });
                      _save(() =>
                          _repo.setPhraseActive(phrase.phraseId, on == true));
                    },
                  ),

                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _resetProgression,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Start over (reset all words to R0)'),
                ),

                const Divider(height: 32),
                _sectionTitle('Privacy'),
                SwitchListTile(
                  title: const Text('Allow sharing progress with family'),
                  subtitle: const Text(
                    'When on, anonymous progress numbers (no audio) may sync to '
                    'the cloud so invited family can see them.',
                  ),
                  value: _consent,
                  onChanged: (v) {
                    setState(() => _consent = v);
                    _save(() async {
                      await _repo.updateProfile(guardianConsentGranted: v);
                      // Turning sharing on? Push whatever's already been recorded.
                      if (v) await SyncService(_repo).pushPending();
                    });
                  },
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  // The R7 probe-question line (audit item 11): shows the current question (or a
  // prompt to add one) and opens the editor on tap.
  Widget _probeControl(PracticePhrase phrase) {
    final q = phrase.probeQuestionText;
    return InkWell(
      onTap: () => _editProbeQuestion(phrase),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.help_outline, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                q == null ? 'Set answer-a-question (R7)…' : 'Q: “$q”',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontStyle:
                          q == null ? FontStyle.italic : FontStyle.normal,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Ease/regress the support rung for one phrase (therapy addendum §4).
  Widget _rungControl(PracticePhrase phrase) {
    final rung = phrase.rung;
    return Row(
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Easier',
          onPressed: rung == entryRung
              ? null
              : () => _setRung(phrase, rung.loweredActive()),
        ),
        Expanded(
          child: Text('${rung.code} · ${rung.title}',
              style: Theme.of(context).textTheme.labelLarge),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Harder',
          onPressed: rung == topRung
              ? null
              : () => _setRung(phrase, rung.raisedActive()),
        ),
      ],
    );
  }

  // Run a DB write, surfacing failures without crashing the UI.
  void _save(Future<void> Function() write) {
    write().catchError((Object e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    });
  }
}
