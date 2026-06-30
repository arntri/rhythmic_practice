import 'cloud.dart';

/// A profile the signed-in user can see (their own, or one shared with them).
class CloudProfileSummary {
  final String id;
  final String? displayName;
  final String? shareCode;
  const CloudProfileSummary({
    required this.id,
    required this.displayName,
    required this.shareCode,
  });
}

/// One attempt as stored in the cloud (metrics only).
class CloudAttempt {
  final String phraseText;
  final int evaluationLabel; // 0 Fail, 1 Pass, 2 Unsure
  final double? syncScore;
  final String attemptedAt;
  const CloudAttempt({
    required this.phraseText,
    required this.evaluationLabel,
    required this.syncScore,
    required this.attemptedAt,
  });
}

/// Read-side of the cloud: list accessible profiles, redeem a share code, and
/// fetch progress. All reads are filtered by row-level security, so a user only
/// ever sees profiles they own or have been invited to.
class CloudSharing {
  CloudSharing._();
  static final CloudSharing instance = CloudSharing._();

  bool get isReady =>
      Cloud.status == CloudStatus.ready && Cloud.client.auth.currentUser != null;

  /// Profiles the user can see, with their share codes.
  Future<List<CloudProfileSummary>> accessibleProfiles() async {
    final rows = await Cloud.client
        .from('practice_profiles')
        .select('id, display_name, share_code');
    return [
      for (final r in rows)
        CloudProfileSummary(
          id: r['id'] as String,
          displayName: r['display_name'] as String?,
          shareCode: r['share_code'] as String?,
        ),
    ];
  }

  /// Redeems a share code, granting this user viewer access. Returns the joined
  /// profile id. Throws if the code is invalid.
  Future<String> joinWithCode(String code) async {
    final result = await Cloud.client
        .rpc('join_profile_with_code', params: {'p_code': code});
    return result as String;
  }

  /// Most recent attempts across everything the user can see, newest first.
  Future<List<CloudAttempt>> recentAttempts({int limit = 100}) async {
    final rows = await Cloud.client
        .from('exercise_attempts')
        .select(
            'phrase_text, evaluation_label, tapping_synchronization_score, attempted_at')
        .order('attempted_at', ascending: false)
        .limit(limit);
    return [
      for (final r in rows)
        CloudAttempt(
          phraseText: (r['phrase_text'] as String?) ?? '',
          evaluationLabel: (r['evaluation_label'] as int?) ?? 2,
          syncScore: (r['tapping_synchronization_score'] as num?)?.toDouble(),
          attemptedAt: (r['attempted_at'] as String?) ?? '',
        ),
    ];
  }
}
