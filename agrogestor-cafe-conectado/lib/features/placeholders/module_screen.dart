import 'package:flutter/material.dart';
import '../../app/app_theme.dart';

class ModuleScreen extends StatelessWidget {
  const ModuleScreen({super.key, required this.title, required this.icon});
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(36),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircleAvatar(
                      radius: 34,
                      backgroundColor: const Color(0xFFE8F1E9),
                      child: Icon(icon, size: 34, color: AppTheme.leaf)),
                  const SizedBox(height: 18),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.forest)),
                  const SizedBox(height: 8),
                  const Text(
                      'Módulo preparado para a próxima etapa de desenvolvimento.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 18),
                  const Text(
                      'A base do aplicativo já está organizada para incluir cadastros, histórico e permissões específicos deste módulo.',
                      textAlign: TextAlign.center,
                      style: TextStyle(height: 1.5)),
                ]),
              ),
            ),
          ),
        ),
      );
}
