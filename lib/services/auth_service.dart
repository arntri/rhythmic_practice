import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/practice_repository.dart';
import 'cloud.dart';

/// Wraps Supabase's email/password authentication.
///
/// "Auth" here means an *app account* (email + password) that the caregiver —
/// and later, family viewers — create inside our app. These accounts live in
/// the Supabase project's user list; nobody but the developer ever sees the
/// Supabase dashboard.
///
/// The app is local-first, so being signed out is a perfectly normal state:
/// practice still works offline. Auth only unlocks the cloud features (sync and
/// remote family viewing).
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  /// Auth needs a working Supabase client. If the cloud isn't configured this
  /// is false and the account UI shows a "not configured" message instead.
  bool get isAvailable => Cloud.status == CloudStatus.ready;

  /// The signed-in user, or null when signed out / unavailable.
  User? get currentUser => isAvailable ? Cloud.client.auth.currentUser : null;
  bool get isSignedIn => currentUser != null;

  /// Fires whenever the user signs in or out, so the UI can rebuild.
  Stream<AuthState> get authChanges => Cloud.client.auth.onAuthStateChange;

  /// Creates a new account. With email confirmation turned off (our setup), the
  /// returned response already contains a session and the user is signed in.
  /// If confirmation is ON, [AuthResponse.session] is null until they confirm.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) {
    return Cloud.client.auth.signUp(email: email, password: password);
  }

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) {
    return Cloud.client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() async {
    await Cloud.client.auth.signOut();
    // Forget the cloud-profile mapping so a different account that signs in next
    // resolves its OWN profile instead of reusing this one's.
    await PracticeRepository().clearCloudProfileId();
  }
}
