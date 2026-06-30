import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/mit_progression.dart';
import 'package:rhythmic_practice/practice/progression.dart';

void main() {
  const engine = MitProgression(); // minBpm 40, default 60, step 10, tier 0.9/10

  ProgressionState st(
    Rung rung, {
    int bpm = MitProgression.defaultBpm,
    bool backedUp = false,
    bool parked = false,
    int tier = 1,
  }) =>
      ProgressionState(
        profileId: 'p',
        phraseId: 1,
        rung: rung,
        bpm: bpm,
        backedUp: backedUp,
        parked: parked,
        syllableTier: tier,
      );

  group('fast loop — 3-rep block at judged rungs (r4–r6)', () {
    test('≥2 Passes in the block advances one rung, resets tempo + backed-up', () {
      final r = engine.evaluateBlock(
          st(Rung.r4, bpm: 40, backedUp: true), [1, 0, 1]); // 2 passes
      expect(r.outcome, RungOutcome.advanced);
      expect(r.state.rung, Rung.r5);
      expect(r.state.bpm, MitProgression.defaultBpm);
      expect(r.state.backedUp, isFalse);
    });

    test('a passing block at the top rung stays at r6', () {
      final r = engine.evaluateBlock(st(Rung.r6), [1, 1, 1]);
      expect(r.state.rung, Rung.r6);
    });

    test('a failing block lowers the tempo first when above the floor', () {
      final r = engine.evaluateBlock(st(Rung.r5, bpm: 60), [0, 0, 1]); // 2 fails
      expect(r.outcome, RungOutcome.slowedTempo);
      expect(r.state.rung, Rung.r5); // unchanged
      expect(r.state.bpm, 50);
      expect(r.state.backedUp, isFalse);
    });

    test('a failing block at the slowest tempo backs up one rung', () {
      final r = engine.evaluateBlock(st(Rung.r5, bpm: 40), [0, 0, 0]);
      expect(r.outcome, RungOutcome.backedUp);
      expect(r.state.rung, Rung.r4);
      expect(r.state.bpm, MitProgression.defaultBpm);
      expect(r.state.backedUp, isTrue);
    });

    test('a failing block at the backed-up rung parks the word', () {
      final r =
          engine.evaluateBlock(st(Rung.r4, bpm: 40, backedUp: true), [0, 0, 1]);
      expect(r.outcome, RungOutcome.parked);
      expect(r.state.parked, isTrue);
    });

    test('a mixed block (no 2 Passes, no 2 Fails) holds — Unsure is neutral', () {
      final before = st(Rung.r5, bpm: 50);
      final r = engine.evaluateBlock(before, [1, 0, 2]); // 1 pass, 1 fail, 1 unsure
      expect(r.outcome, RungOutcome.held);
      expect(r.state, before);
    });

    test('two Unsures and a Pass holds (Unsure counts toward neither)', () {
      final r = engine.evaluateBlock(st(Rung.r5), [2, 2, 1]);
      expect(r.outcome, RungOutcome.held);
    });

    test('a parked word ignores further blocks (even an all-Pass block)', () {
      final before = st(Rung.r5, parked: true);
      final r = engine.evaluateBlock(before, [1, 1, 1]);
      expect(r.outcome, RungOutcome.held);
      expect(r.state, before);
    });
  });

  group('fast loop — r0 (the only un-judged rung) auto-proceeds', () {
    test('r0 auto-proceeds to r1 regardless of the labels', () {
      final r = engine.evaluateBlock(st(Rung.r0), [0, 0, 0]); // labels ignored
      expect(r.outcome, RungOutcome.autoProceeded);
      expect(r.state.rung, Rung.r1);
    });

    test('r1 and r2 are now JUDGED, not auto-proceeded', () {
      // A fail-majority block at r1/r2 must NOT auto-proceed — it eases support.
      for (final rung in [Rung.r1, Rung.r2]) {
        final r = engine.evaluateBlock(st(rung, bpm: 40), [0, 0, 1]);
        expect(r.outcome, isNot(RungOutcome.autoProceeded), reason: '$rung');
        expect(r.state.rung.level, lessThan(rung.level), reason: '$rung backs up');
      }
    });

    test('≥2 Pass at r1/r2 advances one rung', () {
      expect(engine.evaluateBlock(st(Rung.r1), [1, 1, 0]).state.rung, Rung.r2);
      expect(engine.evaluateBlock(st(Rung.r2), [1, 1, 0]).state.rung, Rung.r3);
    });

    test('backing up from r1 lands on r0 (no-trap: r0 then always promotes)', () {
      final r = engine.evaluateBlock(st(Rung.r1, bpm: 40), [0, 0, 0]);
      expect(r.outcome, RungOutcome.backedUp);
      expect(r.state.rung, Rung.r0);
    });
  });

  group('fast loop — R3 (unison-fade) is judged, not auto-proceeded', () {
    test('≥2 Passes at R3 advance to R4', () {
      final r = engine.evaluateBlock(st(Rung.r3), [1, 1, 0]);
      expect(r.outcome, RungOutcome.advanced);
      expect(r.state.rung, Rung.r4);
    });

    test('a failed R3 block NEVER forces R4 — it backs up (at the slow floor)', () {
      final r = engine.evaluateBlock(st(Rung.r3, bpm: 40), [0, 0, 1]);
      expect(r.outcome, RungOutcome.backedUp);
      expect(r.state.rung, Rung.r2); // down to unison, not up to R4
    });

    test('a failed R3 block above the tempo floor slows tempo (stays at R3)', () {
      final r = engine.evaluateBlock(st(Rung.r3, bpm: 60), [0, 0, 0]);
      expect(r.outcome, RungOutcome.slowedTempo);
      expect(r.state.rung, Rung.r3); // held, definitely not R4
    });

    test('a mixed R3 block holds at R3 (does not advance to R4)', () {
      final r = engine.evaluateBlock(st(Rung.r3), [1, 0, 2]);
      expect(r.outcome, RungOutcome.held);
      expect(r.state.rung, Rung.r3);
    });
  });

  group('invariants', () {
    test('a 3-pass block never demotes — advances exactly +1, every rung', () {
      for (final rung in Rung.values) {
        final r = engine.evaluateBlock(st(rung), [1, 1, 1]);
        // Never below the starting rung (passes must not demote).
        expect(r.state.rung.level >= rung.level, isTrue, reason: '$rung');
        // Moves at most one step up.
        expect(r.state.rung.level - rung.level <= 1, isTrue, reason: '$rung');
      }
    });

    test('any block moves the rung by at most one step (no multi-rung jumps)',
        () {
      for (final rung in Rung.values) {
        for (final labels in [
          [1, 1, 1],
          [0, 0, 0],
          [1, 0, 2],
          [0, 1, 2],
        ]) {
          final r = engine.evaluateBlock(st(rung, bpm: 40), labels);
          expect((r.state.rung.level - rung.level).abs() <= 1, isTrue,
              reason: '$rung / $labels → ${r.state.rung}');
        }
      }
    });
  });

  group('fast loop — caregiver rung cap (low-energy session)', () {
    test('advancement is clamped to the cap', () {
      final r = engine.evaluateBlock(st(Rung.r5), [1, 1, 1], rungCap: Rung.r5);
      expect(r.state.rung, Rung.r5); // would be r6, capped at r5
    });

    test('cap also clamps r0 auto-proceed', () {
      final r = engine.evaluateBlock(st(Rung.r0), const [], rungCap: Rung.r0);
      expect(r.state.rung, Rung.r0); // would be r1, capped at r0
    });

    test('a phrase already above the cap is not demoted by it (guard holds)', () {
      // The cap path alone would advance r5 toward the cap (a demotion to r3);
      // the live wiring's pass-never-demotes guard must keep it at r5.
      final before = st(Rung.r5);
      final raw = engine.evaluateBlock(before, [1, 1, 1], rungCap: Rung.r3);
      final guarded =
          engine.guardPassNeverDemotes(before, raw.state, [1, 1, 1]);
      expect(guarded.rung, Rung.r5); // never moved down by the cap
    });
  });

  group('slow loop — syllable-tier gate (default 90% over 5 sessions)', () {
    test('default window/threshold are 5 sessions @ 0.9', () {
      expect(engine.tierWindow, 5);
      expect(engine.tierPassRate, 0.9);
    });

    test('fires only at ≥90% over the last 5 sessions', () {
      expect(engine.shouldRaiseTier(List.filled(5, 1.0)), isTrue);
      expect(engine.shouldRaiseTier(List.filled(5, 0.8)), isFalse);
    });

    test('does not fire before the window (5) is full', () {
      expect(engine.shouldRaiseTier(List.filled(4, 1.0)), isFalse);
    });

    test('exactly 90% average over the window fires', () {
      expect(engine.shouldRaiseTier(List.filled(5, 0.9)), isTrue);
    });

    test('only the last 5 sessions count (earlier weak ones are ignored)', () {
      final rates = [...List.filled(4, 0.0), ...List.filled(5, 1.0)];
      expect(engine.shouldRaiseTier(rates), isTrue);
    });

    test('raising the tier resets the rung to unison and tempo to default', () {
      final next = engine.raiseTier(st(Rung.r6, bpm: 40, tier: 1, backedUp: true));
      expect(next.syllableTier, 2);
      expect(next.rung, Rung.r2); // full support — never raise load AND drop support
      expect(next.bpm, MitProgression.defaultBpm);
      expect(next.backedUp, isFalse);
      expect(next.parked, isFalse);
    });
  });

  group('pass-never-demotes guard (live-wiring invariant)', () {
    test('clamps a pass-majority block that would lower the rung', () {
      // Simulate a glitch where the computed "after" demoted on a pass block.
      final before = st(Rung.r4);
      final bogusAfter = st(Rung.r2); // would be a demotion
      final guarded =
          engine.guardPassNeverDemotes(before, bogusAfter, [1, 1, 0]);
      expect(guarded.rung, Rung.r4); // held at the pre-block rung, never lowered
    });

    test('leaves a legitimate fail-driven demotion alone', () {
      final before = st(Rung.r4);
      final after = st(Rung.r3); // a fail block legitimately backed up
      final guarded = engine.guardPassNeverDemotes(before, after, [0, 0, 1]);
      expect(guarded.rung, Rung.r3); // fails majority → demotion stands
    });

    test('exempts a genuine tier raise (resets rung to unison)', () {
      final before = st(Rung.r5, tier: 1);
      final raised = engine.raiseTier(before); // R2, tier 2
      final guarded = engine.guardPassNeverDemotes(before, raised, [1, 1, 1]);
      expect(guarded.rung, Rung.r2); // tier raise's unison reset is allowed
      expect(guarded.syllableTier, 2);
    });

    test('does not touch a pass block that advances', () {
      final before = st(Rung.r4);
      final advanced = engine.evaluateBlock(before, [1, 1, 1]).state;
      final guarded = engine.guardPassNeverDemotes(before, advanced, [1, 1, 1]);
      expect(guarded.rung, Rung.r5); // advance preserved
    });
  });

  group('device check — a fresh word starts low and Passes never lower it', () {
    test('three consecutive Pass blocks only raise or hold, never drop', () {
      // A brand-new word seeds at the unison default (R2).
      var state = const ProgressionState(profileId: 'p', phraseId: 1);
      expect(state.rung, Rung.r2); // starts low, never R6

      Rung prev = state.rung;
      // Three sessions, each a 3-rep all-Pass block, mirroring the screen's fold:
      // fast loop → (tier gate omitted: <10 sessions) → pass-never-demotes guard.
      for (var session = 0; session < 3; session++) {
        const labels = [1, 1, 1];
        final after = engine.evaluateBlock(state, labels).state;
        state = engine.guardPassNeverDemotes(state, after, labels);
        expect(state.rung.level, greaterThanOrEqualTo(prev.level),
            reason: 'a Pass block must never lower the rung');
        prev = state.rung;
      }
      // R2→R3 (co-production auto-proceed) →R4→R5: climbing, never starts at R6.
      expect(state.rung, Rung.r5);
    });
  });
}
