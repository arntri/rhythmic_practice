import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:vibration/vibration.dart';

import 'beat_scheduler.dart';

/// Drives the tri-sensory metronome: it runs a [Ticker] (which gives a
/// monotonic, drift-free elapsed time), feeds that to the [BeatScheduler], and
/// on each scheduled beat fires the enabled cues — sound, haptic — while
/// continuously exposing a [phase] value for the visual ring.
///
/// Per the brief: the visual and haptic cues fire off the *scheduled beat*, not
/// off the audio finishing (audio latency is variable). Each of the three
/// channels can be switched on/off independently.
class MetronomeEngine {
  MetronomeEngine({
    required TickerProvider vsync,
    int bpm = 60,
    this.soundEnabled = true,
    this.visualEnabled = true,
    this.hapticEnabled = true,
    this.onBeat,
  }) {
    _scheduler = BeatScheduler(bpm: bpm, onBeat: _handleBeat);
    _ticker = vsync.createTicker(_onTick);
    _preloadSound();
    _initHaptics();
  }

  late final BeatScheduler _scheduler;
  late final Ticker _ticker;
  final AudioPlayer _player = AudioPlayer();
  bool _soundReady = false;

  // The volume currently set on the player, so [_playTick] can skip a redundant
  // setVolume call. Matches the 1.0 applied in [_preloadSound].
  double _appliedVolume = 1.0;

  // Haptic capability, probed once at startup (querying every beat is wasteful).
  // Both stay false until the async probe finishes, so the first beat or two may
  // not buzz — imperceptible in practice.
  bool _canVibrate = false;
  bool _hasAmplitudeControl = false;

  // Independently switchable channels (brief §4).
  bool soundEnabled;
  bool visualEnabled;
  bool hapticEnabled;

  /// When true, the beat is the focus (the "feel the beat" / "tap the beat"
  /// phases): the haptic pulse is a little longer/stronger so it's clearly felt.
  bool emphasizeBeat = false;

  /// Tick loudness (0..1). The standalone beat (r0/r1) plays at full volume; the
  /// soft pulse heard *under* the spoken word at the unison rungs is quieter so
  /// it supports the model without competing with it. Applied on the next tick.
  double tickVolume = 1.0;

  /// Optional hook fired on every beat (beat index). The practice FSM will use
  /// this later; the metronome test screen doesn't need it.
  final void Function(int beatIndex)? onBeat;

  /// 0.0 exactly on the beat, rising toward 1.0 just before the next one.
  /// A widget listens to this to paint the pulsing ring.
  final ValueNotifier<double> phase = ValueNotifier<double>(0);

  Duration _lastElapsed = Duration.zero;

  int get bpm => _scheduler.bpm;
  bool get isRunning => _scheduler.isRunning;

  /// Current beat phase (0.0 exactly on a beat → ~1.0 just before the next),
  /// independent of the visual channel. Used to start guide playback on the next
  /// beat so the warped one-syllable-per-beat audio lines up with the pulse.
  double get currentPhase => _scheduler.phaseAt(_lastElapsed);

  /// Load the tick into the player once, at startup, so the first beat isn't
  /// delayed (brief §4). Failure is non-fatal — on platforms where desktop
  /// audio isn't available the metronome still runs visually/haptically.
  Future<void> _preloadSound() async {
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      // Play the tick at full device volume — the asset itself carries the gain
      // (and its soft attack/decay envelope, so it stays click-free). The audible
      // tick is still gated by [soundEnabled], which the practice screen drops to
      // false during capture (r4–r6) so the louder tick never bleeds into the mic.
      await _player.setVolume(1.0);
      await _player.setSource(AssetSource('audio/tick.wav'));
      _soundReady = true;
    } catch (e) {
      _soundReady = false;
      debugPrint('Metronome: sound preload failed (can be normal on desktop): $e');
    }
  }

  void start() {
    if (_scheduler.isRunning) return;
    _scheduler.start();
    _ticker.start();
  }

  void stop() {
    _ticker.stop();
    _scheduler.stop();
    phase.value = 0;
  }

  /// Adjust tempo, re-anchoring cleanly to "now" so there's no double-beat.
  void setBpm(int newBpm) => _scheduler.setBpm(newBpm, _lastElapsed);

  // Called every frame by the Ticker with elapsed time since start().
  void _onTick(Duration elapsed) {
    _lastElapsed = elapsed;
    _scheduler.update(elapsed); // may fire one or more beats
    // Update the visual phase every frame for smooth motion.
    phase.value = visualEnabled ? _scheduler.phaseAt(elapsed) : 0;
  }

  // Called by the scheduler exactly on each beat.
  //
  // The scheduler replays every beat a stalled frame missed so the FSM's beat
  // counting stays on the absolute grid — but the *cues* must not be replayed.
  // A long UI-thread stall (the attempt-scoring work at the caregiver verdict
  // used to be one) would otherwise dump five or six ticks into a single frame,
  // heard as a stutter burst. [shouldSoundBeat] drops the overtaken ones so the
  // pulse stays even: a stall costs a beat or two of silence, never a burst.
  void _handleBeat(int index, Duration scheduledTime) {
    final onTime = shouldSoundBeat(
      scheduled: scheduledTime,
      now: _lastElapsed,
      beatPeriodUs: _scheduler.beatPeriodUs,
    );
    if (onTime) {
      if (soundEnabled) _playTick();
      if (hapticEnabled) _haptic();
    }
    onBeat?.call(index);
  }

  void _playTick() {
    if (!_soundReady) return;
    // Fire-and-forget: restart the preloaded clip from the top. We intentionally
    // do NOT await here — awaiting would couple beat timing to audio latency.
    // The volume is only re-sent when it actually changes (it changes at rung
    // seams, not per beat), so the common tick costs two platform round-trips
    // rather than three — it adds up on a low-end phone.
    final volume = tickVolume.clamp(0.0, 1.0);
    Future<void> tick = _player.seek(Duration.zero);
    if (volume != _appliedVolume) {
      _appliedVolume = volume;
      tick = tick.then((_) => _player.setVolume(volume));
    }
    tick.then((_) => _player.resume()).catchError((_) {});
  }

  /// Probe the vibrator once. On platforms without one (e.g. desktop) this
  /// leaves [_canVibrate] false so [_haptic] is a no-op.
  Future<void> _initHaptics() async {
    try {
      // `== true` so this is safe whether the plugin returns bool or bool?.
      _canVibrate = await Vibration.hasVibrator() == true;
      _hasAmplitudeControl =
          _canVibrate && await Vibration.hasAmplitudeControl() == true;
    } catch (e) {
      _canVibrate = false;
      debugPrint('Metronome: haptics unavailable: $e');
    }
  }

  void _haptic() {
    if (!_canVibrate) return;
    // A short, sharp pulse on the beat — long enough to feel, short enough not
    // to blur into the next beat. Full amplitude where supported so it's clearly
    // felt (Samsung's system "impact" haptics were too weak); a longer pulse in
    // the beat-focused phases. Fire-and-forget: we never await, so haptics can't
    // couple to beat timing (brief §4).
    Vibration.vibrate(
      duration: emphasizeBeat ? 70 : 40,
      amplitude: _hasAmplitudeControl ? 255 : -1,
    ).catchError((_) {});
  }

  void dispose() {
    _ticker.dispose();
    _player.dispose();
    phase.dispose();
  }
}
