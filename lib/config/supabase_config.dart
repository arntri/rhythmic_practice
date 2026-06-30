/// Supabase connection settings.
///
/// The two values are supplied at build time via --dart-define so the secret
/// is never committed to source control. The easiest way is a (gitignored)
/// JSON file:
///
///   1. Copy `supabase.example.json` -> `supabase.json` in the project root.
///   2. Fill in the two values from your Supabase project:
///        Supabase dashboard -> Project Settings -> API Keys
///        - SUPABASE_URL      = "Project URL" (e.g. https://abcdxyz.supabase.co)
///        - SUPABASE_ANON_KEY = the publishable / "anon public" client key
///                              (starts with "sb_publishable_" on newer
///                              projects, or is the long "anon public" token on
///                              older ones). NEVER the "secret"/"service_role".
///   3. Build/run with: flutter run --dart-define-from-file=supabase.json
///
/// The publishable key is designed to be embedded in client apps — it only
/// grants the access our row-level-security rules allow.
///
/// When the defines are absent (e.g. no supabase.json passed), both values are
/// empty and the app runs fully locally with no cloud connection.
class SupabaseConfig {
  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String publishableKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  /// True only when both values have been filled in. The app checks this so it
  /// can run offline/local-only when the cloud isn't set up yet.
  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}
