import 'package:flutter/material.dart';

import '../auth/user_model.dart';
import 'licensing_service.dart';

class LicenseNotice extends StatelessWidget {
  const LicenseNotice({super.key, required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final farmId = user.farmId;
    if (farmId == null) return const SizedBox.shrink();
    return FutureBuilder<FarmEntitlement?>(
      future: LicensingService().load(farmId),
      builder: (context, result) => AnimatedBuilder(
        animation: LicensingService(),
        builder: (context, _) {
          final status = LicensingService().current ?? result.data;
          if (status == null) return const SizedBox.shrink();
          final effectiveStatus = status.effectiveStatus;
          final expired = effectiveStatus == 'expired';
          final warning = (effectiveStatus == 'trial' && (status.effectiveDaysRemaining ?? 30) <= 5) || effectiveStatus == 'validation_required';
          if (!expired && !warning) return const SizedBox.shrink();
          return Material(
            color: expired ? Colors.red.shade50 : Colors.amber.shade50,
            child: ListTile(
              dense: true,
              leading: Icon(expired ? Icons.lock_clock : Icons.hourglass_bottom,
                  color: expired ? Colors.red.shade800 : Colors.orange.shade900),
              title: Text(status.notice, style: const TextStyle(fontSize: 13)),
            ),
          );
        },
      ),
    );
  }
}
