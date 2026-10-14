/// How much practice is actually happening, in **minutes a day**, against a
/// stated target.
///
/// **Where the target comes from.** MIT was validated as an intensive therapy:
/// the trials ran long daily sessions over months. Around an hour a day, five
/// days a week, is the shape of what the research asked for. Home practice with
/// a family member will often fall short of that, and the honest thing is to
/// name the target rather than hide it behind a bar that happens to look full.
///
/// **Two short blocks count the same as one long one.** That is the single most
/// useful thing this screen can tell a caregiver who thinks they are behind, and
/// it is why the unit is minutes-per-day rather than sessions.
///
/// **No streak, and no missed-day marker.** A streak turns a therapy into a
/// thing you can break, and the person most likely to break it is the one having
/// the worst week. Days below target are shown in the neutral colour — present,
/// unremarked.
///
/// Nothing here gates or judges anything. It is a mirror.
class PracticeDose {
  const PracticeDose({
    required this.targetMinutesPerDay,
    required this.days,
    required this.averageMinutesPerDay,
    required this.minutesLast28,
    required this.daysMetTarget,
  });

  /// The daily goal, in minutes.
  final int targetMinutesPerDay;

  /// The last seven days, **oldest first** so it reads left to right.
  final List<DoseDay> days;

  /// Mean minutes a day across those seven days, rounded. Includes the days with
  /// nothing on them — an average that quietly skipped the empty days would
  /// flatter the number into meaninglessness.
  final int averageMinutesPerDay;

  /// Total minutes over the last 28 days.
  final int minutesLast28;

  /// How many of the last seven days reached the target.
  final int daysMetTarget;

  /// The average as a fraction of the target, capped at 1 for display.
  double get fractionOfTarget => targetMinutesPerDay <= 0
      ? 0
      : (averageMinutesPerDay / targetMinutesPerDay).clamp(0.0, 1.0);

  /// Whether there is enough history to say anything. Below this the screen
  /// should say so rather than draw a confident-looking chart of two bars.
  bool get hasEnoughHistory => days.where((d) => d.minutes > 0).length >= 3;

  /// Build the picture from per-day minutes, keyed 'YYYY-MM-DD'.
  ///
  /// [today] is injected so this stays a pure function and the tests don't have
  /// to wait for midnight.
  factory PracticeDose.from(
    Map<String, int> minutesByDay, {
    required DateTime today,
    int targetMinutesPerDay = defaultTargetMinutesPerDay,
  }) {
    String key(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    const initials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

    final week = <DoseDay>[];
    var weekTotal = 0;
    for (var i = 6; i >= 0; i--) {
      final date = today.subtract(Duration(days: i));
      final minutes = minutesByDay[key(date)] ?? 0;
      weekTotal += minutes;
      week.add(
        DoseDay(
          date: date,
          initial: initials[date.weekday - 1],
          minutes: minutes,
          metTarget: targetMinutesPerDay > 0 && minutes >= targetMinutesPerDay,
        ),
      );
    }

    var total28 = 0;
    for (var i = 0; i < 28; i++) {
      total28 += minutesByDay[key(today.subtract(Duration(days: i)))] ?? 0;
    }

    return PracticeDose(
      targetMinutesPerDay: targetMinutesPerDay,
      days: week,
      averageMinutesPerDay: (weekTotal / 7).round(),
      minutesLast28: total28,
      daysMetTarget: week.where((d) => d.metTarget).length,
    );
  }

  /// About an hour a day — the shape of what the research protocols asked for.
  /// Adjustable, because a target nobody can reach is not a target.
  static const int defaultTargetMinutesPerDay = 60;

  /// The allowed range for the caregiver's own target.
  static const int minTargetMinutesPerDay = 10;
  static const int maxTargetMinutesPerDay = 90;

  /// The step the caregiver's picker moves in.
  static const int targetStepMinutes = 10;
}

/// One day in the seven-day view.
class DoseDay {
  const DoseDay({
    required this.date,
    required this.initial,
    required this.minutes,
    required this.metTarget,
  });

  final DateTime date;

  /// Single-letter weekday label, Monday-first.
  final String initial;
  final int minutes;
  final bool metTarget;
}
