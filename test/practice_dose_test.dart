// Practice dose. MIT was validated as an intensive therapy — the trials ran long
// daily sessions over months — so the target is MINUTES A DAY, and it is stated
// on screen rather than implied by a bar that happens to look full.
//
// The rules that matter here are mostly about not being unkind with a number.
// There is deliberately no streak: a streak turns a therapy into a thing you can
// break, and the person most likely to break it is the one having the worst week.

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analytics/practice_dose.dart';

void main() {
  final today = DateTime(2026, 9, 1); // a Tuesday
  String key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  Map<String, int> mins(Map<int, int> agoToMinutes) => {
    for (final e in agoToMinutes.entries)
      key(today.subtract(Duration(days: e.key))): e.value,
  };

  test('averages minutes across the whole week, empty days included', () {
    // An average that skipped the empty days would flatter the number into
    // meaninglessness — three good days is not "60 min a day".
    final dose = PracticeDose.from(
      mins({0: 60, 1: 60, 2: 60}),
      today: today,
      targetMinutesPerDay: 60,
    );
    expect(dose.averageMinutesPerDay, 26); // 180 / 7
  });

  test('the week reads oldest first, so it draws left to right', () {
    final dose = PracticeDose.from(mins({0: 10, 6: 40}), today: today);
    expect(dose.days, hasLength(7));
    expect(dose.days.first.minutes, 40, reason: 'six days ago, on the left');
    expect(dose.days.last.minutes, 10, reason: 'today, on the right');
    expect(dose.days.last.date.day, today.day);
  });

  test('weekday initials are Monday-first', () {
    final dose = PracticeDose.from(const {}, today: today);
    expect(dose.days.last.initial, 'T', reason: '1 Sep 2026 is a Tuesday');
  });

  test('a day meets the target by reaching it, not by being the best day', () {
    final dose = PracticeDose.from(
      mins({0: 60, 1: 59, 2: 90}),
      today: today,
      targetMinutesPerDay: 60,
    );
    final byAgo = {for (final d in dose.days) today.difference(d.date).inDays: d};
    expect(byAgo[0]!.metTarget, isTrue);
    expect(byAgo[1]!.metTarget, isFalse);
    expect(byAgo[2]!.metTarget, isTrue);
    expect(dose.daysMetTarget, 2);
  });

  test('two short blocks count the same as one long one', () {
    // The most useful thing this screen can tell a caregiver who thinks they are
    // behind, and the reason the unit is minutes rather than sessions.
    final split = PracticeDose.from(mins({0: 20, 1: 20}), today: today);
    final single = PracticeDose.from(mins({0: 40}), today: today);
    expect(split.minutesLast28, single.minutesLast28);
  });

  test('counts a whole 28 days, and nothing older', () {
    final dose = PracticeDose.from(
      mins({0: 10, 27: 10, 28: 999, 60: 999}),
      today: today,
    );
    expect(dose.minutesLast28, 20);
  });

  test('the fraction of target is capped, so beating it is not 140%', () {
    final dose = PracticeDose.from(
      mins({for (var i = 0; i < 7; i++) i: 120}),
      today: today,
      targetMinutesPerDay: 60,
    );
    expect(dose.averageMinutesPerDay, 120);
    expect(dose.fractionOfTarget, 1.0);
  });

  test('no history is zero, not an error, and says so', () {
    final dose = PracticeDose.from(const {}, today: today);
    expect(dose.averageMinutesPerDay, 0);
    expect(dose.minutesLast28, 0);
    expect(dose.daysMetTarget, 0);
    expect(dose.days, hasLength(7));
    expect(dose.hasEnoughHistory, isFalse);
  });

  test('three days of history is enough to say something', () {
    expect(
      PracticeDose.from(mins({0: 5, 1: 5}), today: today).hasEnoughHistory,
      isFalse,
    );
    expect(
      PracticeDose.from(mins({0: 5, 1: 5, 2: 5}), today: today)
          .hasEnoughHistory,
      isTrue,
    );
  });

  test('the target is stated, adjustable, and defaults to the research shape', () {
    expect(PracticeDose.defaultTargetMinutesPerDay, 60);
    expect(PracticeDose.minTargetMinutesPerDay, lessThan(60));
    expect(PracticeDose.maxTargetMinutesPerDay, greaterThan(60));
  });
}
