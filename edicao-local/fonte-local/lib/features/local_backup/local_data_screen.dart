import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../auth/auth_service.dart';
import 'local_backup_service.dart';

class LocalDataScreen extends StatefulWidget {
  const LocalDataScreen({super.key});
  @override
  State<LocalDataScreen> createState() => _LocalDataState();
}

class _LocalDataState extends State<LocalDataScreen> {
  final _service = LocalBackupService();
  bool _busy = false;
  String? _message;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _message = error is FormatException
            ? error.message
            : 'Nao foi possivel concluir. Os dados atuais foram preservados. Confira o arquivo e tente novamente.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() => _run(() async {
        final bytes = await _service.create();
        if (!mounted) return;
        final stamp = DateTime.now()
            .toIso8601String()
            .replaceAll(':', '-')
            .split('.')
            .first;
        final path = await FilePicker.saveFile(
            dialogTitle: 'Salvar backup do AgroGestor',
            fileName: 'AgroGestor-Local-$stamp.agrobackup',
            type: FileType.custom,
            allowedExtensions: ['agrobackup'],
            bytes: bytes);
        if (path != null && mounted) {
          setState(() => _message =
              'Backup salvo. Guarde uma copia fora deste celular e confira o arquivo antes de depender dele.');
        }
      });
  Future<Uint8List> _read(File file) async {
    if (await file.length() > LocalBackupService.maxBytes) {
      throw const FormatException('O arquivo excede 64 MB.');
    }
    return file.readAsBytes();
  }

  Future<void> _import() => _run(() async {
        final item = await FilePicker.pickFile(
            dialogTitle: 'Escolher backup do AgroGestor', type: FileType.any);
        if (item == null) return;
        final length = await item.length();
        if (length != null && length > LocalBackupService.maxBytes) {
          throw const FormatException('O arquivo excede 64 MB.');
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in item.readAsByteStream()) {
          if (builder.length + chunk.length > LocalBackupService.maxBytes) {
            throw const FormatException('O arquivo excede 64 MB.');
          }
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        await _confirm(bytes);
      });
  Future<void> _previous() => _run(() async {
        final files = await _service.previousCopies();
        if (files.isEmpty) {
          if (mounted) {
            setState(() =>
                _message = 'Ainda nao ha copia anterior a uma restauracao.');
          }
          return;
        }
        if (!mounted) return;
        final selected = await showDialog<File>(
            context: context,
            builder: (ctx) => SimpleDialog(
                    title: const Text('Copia anterior a restauracao'),
                    children: [
                      for (final file in files.take(15))
                        SimpleDialogOption(
                            onPressed: () => Navigator.pop(ctx, file),
                            child: Text(
                                file.path.split(Platform.pathSeparator).last)),
                    ]));
        if (selected != null) await _confirm(await _read(selected));
      });
  Future<void> _confirm(Uint8List bytes) async {
    final data = _service.inspect(bytes);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Restaurar backup?'),
              content: SingleChildScrollView(
                  child: Text(
                      'Gerado em: ${data['createdAt']}\n${(data['records'] as List).length} registros operacionais\n${(data['catalog'] as List).length} cadastros de propriedades e areas\n${(data['photos'] as Map).length} fotos\n\nA restauracao substitui os dados locais atuais; nao soma os cadastros. Uma copia do estado anterior sera preservada neste aparelho. Voce voltara a tela de entrada para recarregar os dados.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancelar')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Restaurar'))
              ],
            ));
    if (confirmed != true) return;
    await _service.restore(bytes);
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Backup restaurado'),
                content: const Text(
                    'Os cadastros foram recuperados. Toque em Continuar e depois em Usar neste aparelho. A copia anterior fica em Dados locais > Recuperar copia anterior.'),
                actions: [
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Continuar'))
                ]));
    await AuthService().logout();
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(18), children: [
        Text('Dados neste aparelho',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
            'Modo local, sem servidor. Seus cadastros ficam neste celular.'),
        const SizedBox(height: 12),
        if (_busy)
          const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator()),
        FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.save_alt),
            label: const Text('Salvar backup')),
        const SizedBox(height: 10),
        OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.restore),
            label: const Text('Restaurar backup')),
        const SizedBox(height: 8),
        TextButton(
            onPressed: _busy ? null : _previous,
            child: const Text('Recuperar copia anterior')),
        if (_message != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(12), child: Text(_message!))),
        const SizedBox(height: 12),
        const Card(
            child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                    'O backup inclui cadastros, operacoes, historico de alteracoes e fotos vinculadas. Nao ha compartilhamento nem backup automatico.'))),
        const SizedBox(height: 10),
        const Text(
            'Guarde uma copia fora deste celular, em local privado. O arquivo nao possui senha.'),
        const SizedBox(height: 10),
        const Text(
            'O backup dos cadastros não contém a licença nem a chave privada. Em outro celular, ative a instalação de destino antes de restaurar os dados. Uma nova autorização não desativa automaticamente o aparelho anterior.'),
        const SizedBox(height: 10),
        const Text(
            'Atualize instalando por cima da mesma edicao. Desinstalar ou limpar os dados apaga os cadastros locais.'),
      ]);
}
