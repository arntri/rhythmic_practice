// ignore_for_file: avoid_print
//
// Not a behavioural assertion — a DEMONSTRATION harness. It drives the REAL
// [MitProgression] engine (the same one the practice screen uses) through a full
// multi-session climb for one word and prints the exact `[PROGRESSION]` log lines
// the screen emits to logcat (init / R0 windows / tier-gate / block before→after).
//
// It exists so the progression + tier-gate logging can be inspected without a
// device. On a real Android session these same lines appear in `flutter run` /
// `adb logcat`. Run:  flutter test test/progression_log_sim_test.dart
//
// What it shows: a word starts LOW (R0), R0 always promotes after its two
// windows, repeated Passes climb R1→R7 and NEVER drop, and the syllable tier
// only jumps after sustained ~90% mastery AT the top rung (R7, answer-the-
// question), resetting to R2.

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/mit_progression.dart';
import 'package:rhythmic_practice/practice/progression.dart';

void main() {
  test('SIM: one word climbs R0→R7, then the tier gate fires (prints the log)', () {
    const engine = MitProgression(); // 40–70 BPM, tier 10 sessions @ 0.9
    const id = 7;
    const text = 'Help';
    const r0WindowMs = 6000;
    const r0Threshold = 0.5;

    // Top-rung (R7) per-session pass-rate history, oldest→newest. The repo query
    // builds this from attempts with rung_at_attempt >= 7; here we append 1.0 for
    // each session the word is practised AT R7 (all-Pass), exactly as the live
    // query would. Sessions below R7 contribute nothing (the gate's whole point).
    final topRungRates = <double>[];

    var state = const ProgressionState(profileId: 'p', phraseId: id, rung: Rung.r0);

    // A scripted run: R0 (window mechanism), then all-Pass blocks until the tier
    // gate trips. Enough R7 sessions (≥10) to demonstrate the gate firing.
    const sessions = 18; // enough R7 sessions (≥10) for the wider window

    print('=== SIM: word "$text" climbing the ladder ===');
    for (var s = 1; s <= sessions; s++) {
      final before = state;
      print('[PROGRESSION] init phrase=$id "$text" '
          'seedRung=${before.rung.code} tier=${before.syllableTier} bpm=${before.bpm}');

      // --- Build this session's block of caregiver labels (or R0 windows) -----
      List<int> labels;
      String r0note = '';
      if (before.rung == Rung.r0) {
        // R0: simulate window 1 missed → window 2 → force-promote (worst case,
        // proving the no-trap guarantee). Tap performance never blocks.
        print('[PROGRESSION] R0 phrase=$id "$text" window1 start '
            '(${r0WindowMs}ms, threshold $r0Threshold)');
        print('[PROGRESSION] R0 phrase=$id window1 missed score=0.20 → offering window2');
        print('[PROGRESSION] R0 phrase=$id force-promote after window2');
        r0note = ' r0=window2-forced';
        labels = const [2]; // neutral; r0 block size is 1
      } else {
        labels = const [1, 1, 1]; // caregiver passes the 3-rep block
      }

      // --- Fast loop -----------------------------------------------------------
      final result = engine.evaluateBlock(before, labels);
      var after = result.state;

      // This session's R7 attempts are already saved before the block evaluates,
      // so a session AT R7 contributes to its OWN tier-gate check (as live). The
      // history is scoped to the CURRENT tier (live: tier_at_attempt filter).
      if (before.rung == topRung) topRungRates.add(1.0);

      // --- Slow loop (tier gate): top-rung-only, current-tier pass-rate -------
      // Only fires while the word is at the top rung (a back-up can't trip it).
      final willRaise =
          before.rung == topRung && engine.shouldRaiseTier(topRungRates);
      print('[PROGRESSION] tier-gate phrase=$id "$text" '
          'tier=${before.syllableTier} atTopRung=${before.rung == topRung} '
          'topRungPassRates=${topRungRates.map((r) => r.toStringAsFixed(2)).toList()} '
          'sessions=${topRungRates.length} '
          'need ${engine.tierWindow}@≥${engine.tierPassRate} → raiseTier=$willRaise');
      if (willRaise) {
        after = engine.raiseTier(after);
        topRungRates.clear(); // new tier starts a fresh mastery window
      }

      // --- Pass-never-demotes guard -------------------------------------------
      after = engine.guardPassNeverDemotes(before, after, labels);

      final p = labels.where((l) => l == 1).length;
      final f = labels.where((l) => l == 0).length;
      final u = labels.where((l) => l == 2).length;
      print('[PROGRESSION] block phrase=$id "$text" labels=$labels '
          '(P=$p F=$f U=$u)$r0note '
          'rung ${before.rung.code}→${after.rung.code} '
          'tier ${before.syllableTier}→${after.syllableTier} '
          'bpm ${before.bpm}→${after.bpm} outcome=${result.outcome.name}');

      // Passes must NEVER demote (the guarantee), tier raises excepted.
      final tierRaised = after.syllableTier > before.syllableTier;
      if (!tierRaised && (p > f)) {
        expect(after.rung.level, greaterThanOrEqualTo(before.rung.level));
      }

      state = after;
    }

    // By the end the tier gate has fired at least once (tier > 1) and reset to R2.
    expect(state.syllableTier, greaterThan(1));
  });
}
