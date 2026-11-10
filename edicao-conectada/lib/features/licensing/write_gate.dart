import 'package:flutter/material.dart';

import '../auth/farm_access_policy.dart';
import '../sync/sync_errors.dart';
import 'licensing_service.dart';

Future<bool> runLicensedWrite(BuildContext context, Future<void> Function() write) async {
  try {
    await write();
    return true;
  } on LicenseWriteBlocked catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
    return false;
  } on FarmAccessDenied catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
    return false;
  } on SyncConflictWriteBlocked catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
    return false;
  }
}
