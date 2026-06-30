import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';

/// A simple account screen: create an account, sign in, or sign out.
///
/// This is the caregiver's entry point to the cloud. Family viewers will use
/// the very same screen to make their own accounts later (step 2e).
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _auth = AuthService.instance;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  // When true we show "Create account"; when false, "Sign in".
  bool _isSignUp = false;
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _message = 'Please enter an email and password.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      if (_isSignUp) {
        final response = await _auth.signUp(email: email, password: password);
        // If email confirmation is still ON, there's no session yet.
        if (response.session == null) {
          _message = 'Account created. Please confirm your email, then sign in.';
        }
      } else {
        await _auth.signIn(email: email, password: password);
      }
    } on AuthException catch (e) {
      _message = e.message; // friendly message from Supabase, e.g. wrong password
    } catch (e) {
      _message = 'Something went wrong: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            // Rebuild whenever the user signs in or out.
            child: StreamBuilder<AuthState>(
              stream: _auth.isAvailable ? _auth.authChanges : null,
              builder: (context, _) {
                if (!_auth.isAvailable) {
                  return const Text(
                    'Cloud is not configured, so accounts are unavailable. '
                    'The app still works fully on this device.',
                    textAlign: TextAlign.center,
                  );
                }
                return _auth.isSignedIn ? _buildSignedIn() : _buildSignedOut();
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignedIn() {
    final email = _auth.currentUser?.email ?? '(unknown)';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 48),
        const SizedBox(height: 12),
        const Text('Signed in as'),
        Text(email, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _auth.signOut(),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }

  Widget _buildSignedOut() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _isSignUp ? 'Create an account' : 'Sign in',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Email',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: true,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_isSignUp ? 'Create account' : 'Sign in'),
          ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _isSignUp = !_isSignUp;
                    _message = null;
                  }),
          child: Text(_isSignUp
              ? 'I already have an account — sign in'
              : 'New here? Create an account'),
        ),
        if (_message != null) ...[
          const SizedBox(height: 8),
          Text(
            _message!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}
