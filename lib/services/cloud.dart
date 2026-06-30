import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';

/// How the cloud connection currently stands.
enum CloudStatus {
  /// No credentials filled in — the app runs purely local. This is fine.
  disabled,

  /// Supabase client initialised successfully and is ready to use.
  ready,

  /// Credentials were present but initialising failed (see [Cloud.lastError]).
  error,
}

/// Thin wrapper around the Supabase client.
///
/// The whole point of "local-first" is that the app must work even if the cloud
/// is missing or unreachable. So initialising the cloud NEVER throws up to the
/// app — if it fails we just record an error status and carry on locally.
class Cloud {
  Cloud._();

  static CloudStatus status = CloudStatus.disabled;
  static Object? lastError;

  /// Called once at startup, after Flutter is initialised. Safe to call when no
  /// credentials are configured — it simply leaves the cloud disabled.
  static Future<void> initialize() async {
    if (!SupabaseConfig.isConfigured) {
      status = CloudStatus.disabled;
      return;
    }
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: SupabaseConfig.publishableKey,
      );
      status = CloudStatus.ready;
    } catch (e) {
      status = CloudStatus.error;
      lastError = e;
    }
  }

  /// The Supabase client. Only valid once [status] is [CloudStatus.ready].
  static SupabaseClient get client => Supabase.instance.client;
}
