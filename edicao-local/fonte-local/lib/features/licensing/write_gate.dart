import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/farm_access_policy.dart';
import '../sync/sync_errors.dart';
import 'licensing_service.dart';
import '../local_activation/local_activation_service.dart';

Future<bool> runLicensedWrite(
    BuildContext context, Future<void> Function() write) async {
  try {
    await write();
    return true;
  } on LocalActivationException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
    return false;
  } on DatabaseException {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Não foi possível salvar no aparelho. Confira o espaço disponível e tente novamente.')));
    }
    return false;
  } on FormatException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
    return false;
  } on LicenseWriteBlocked catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
    return false;
  } on FarmAccessDenied catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
    return false;
  } on SyncConflictWriteBlocked catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
    return false;
  }
}
