import 'package:flutter/material.dart';
import '../features/auth/auth_service.dart';
import '../features/auth/login_screen.dart';
import '../features/shell/app_shell.dart';
import 'app_theme.dart';
import '../features/local_activation/activation_gate.dart';
import '../features/local_activation/local_activation_service.dart';

class AgroApp extends StatelessWidget {
  const AgroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthService(),
      builder: (context, _) {
        final auth = AuthService();
        return MaterialApp(
          title: 'AgroGestor',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          home: LocalActivationService.instance.enforced
              ? ActivationGate(
                  child: auth.isAuthenticated
                      ? const AppShell()
                      : const LoginScreen())
              : auth.isAuthenticated
                  ? const AppShell()
                  : const LoginScreen(),
        );
      },
    );
  }
}
