import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/auth/auth_header.dart';
import 'forgot_password_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _isResendingVerification = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Show a one-time notice if force-logged-out elsewhere, then clear it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final authProvider = context.read<AuthProvider>();
      final message = authProvider.forceLogoutMessage;
      if (message != null) {
        authProvider.clearForceLogoutMessage();
        SnackBarHelper.show(context, message, duration: const Duration(seconds: 6));
      }
    });
  }

  void _clearLoginFeedback() {
    if (_errorMessage != null) {
      setState(() => _errorMessage = null);
    }
    context.read<AuthProvider>().clearLoginFeedback();
  }

  Future<void> _openRegistration() async {
    _clearLoginFeedback();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RegisterScreen()),
    );
    if (!mounted) return;
    _clearLoginFeedback();
  }

  Future<void> _openForgotPassword() async {
    _clearLoginFeedback();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
    );
    if (!mounted) return;
    _clearLoginFeedback();
  }

  void _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final error = await authProvider.login(
      _emailController.text.trim(),
      _passwordController.text.trim(),
    );

    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });

    if (error != null) {
      setState(() {
        _errorMessage = error;
      });
    }
  }

  Future<void> _resendVerification() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;

    setState(() => _isResendingVerification = true);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final message = await authProvider.resendVerificationEmail(email);
    if (!mounted) return;
    setState(() => _isResendingVerification = false);
    SnackBarHelper.show(context, message ?? 'Verification email sent.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AuthHeader(
                    icon: Icons.chat_bubble_rounded,
                    title: 'Welcome Back!',
                    subtitle: 'Sign in to continue messaging',
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(color: AppColors.softShadow, blurRadius: 20, offset: const Offset(0, 8)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_errorMessage != null)
                          Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: AppColors.errorBackground,
                              border: Border.all(color: AppColors.errorBorder),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(_errorMessage!,
                                style: const TextStyle(color: AppColors.error)),
                          ),
                        if (context.watch<AuthProvider>().emailVerificationRequired)
                          Container(
                            padding: const EdgeInsets.all(14),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.08),
                              border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.mark_email_unread_outlined, color: AppColors.primary, size: 22),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Please verify your email to continue.',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      _isResendingVerification
                                          ? SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                                            )
                                          : InkWell(
                                              onTap: _resendVerification,
                                              child: Text(
                                                'Resend verification email',
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w700,
                                                  color: AppColors.primary,
                                                  decoration: TextDecoration.underline,
                                                ),
                                              ),
                                            ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        TextFormField(
                          controller: _emailController,
                          onChanged: (_) => _clearLoginFeedback(),
                          decoration: const InputDecoration(
                              labelText: 'Email', prefixIcon: Icon(Icons.email)),
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          validator: (value) =>
                              value!.isEmpty ? 'Please enter your email' : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _passwordController,
                          onChanged: (_) => _clearLoginFeedback(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                              ),
                              tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                            ),
                          ),
                          obscureText: _obscurePassword,
                          textInputAction: TextInputAction.done,
                          // Lets pressing Enter/Return submit the form, same as tapping Log In.
                          onFieldSubmitted: (_) => _login(),
                          validator: (value) =>
                              value!.isEmpty ? 'Please enter your password' : null,
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _openForgotPassword,
                            child: Text('Forgot password?',
                                style: TextStyle(color: AppColors.textSecondary)),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: _isLoading ? null : _login,
                          child: _isLoading
                              ? const CircularProgressIndicator(color: AppColors.onPrimary)
                              : const Text('Log In',
                                  style: TextStyle(
                                      fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _openRegistration,
                    child: Text("Don't have an account? Sign Up",
                        style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

