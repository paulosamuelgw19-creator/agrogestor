import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class LocalPhotoThumbnail extends StatelessWidget {
  const LocalPhotoThumbnail(
      {super.key, required this.path, required this.fallback});

  final String path;
  final Widget fallback;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          cacheWidth: 132,
          errorBuilder: (_, __, ___) => fallback,
        ),
      );
}

class LocalPhotoField extends StatefulWidget {
  const LocalPhotoField({
    super.key,
    required this.photoPath,
    required this.onChanged,
    this.enabled = true,
  });

  final String? photoPath;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  @override
  State<LocalPhotoField> createState() => _LocalPhotoFieldState();
}

class _LocalPhotoFieldState extends State<LocalPhotoField> {
  bool _busy = false;
  String? _error;

  Future<void> _choose() async {
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Adicionar foto'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, ImageSource.camera),
            child: const Text('Tirar foto'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, ImageSource.gallery),
            child: const Text('Escolher da galeria'),
          ),
        ],
      ),
    );
    if (!mounted || source == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final photo = await ImagePicker()
          .pickImage(source: source, maxWidth: 1600, imageQuality: 85);
      if (photo == null) return;
      final length = await photo.length();
      if (length <= 0 || length > 8 * 1024 * 1024) {
        throw const FormatException('Escolha uma foto de até 8 MB.');
      }
      final root = await getApplicationSupportDirectory();
      final separator = Platform.pathSeparator;
      final directory = Directory('${root.path}${separator}attachments');
      await directory.create(recursive: true);
      final path =
          '${directory.path}${separator}cadastro-${const Uuid().v4()}.img';
      await photo.saveTo(path);
      if (mounted) widget.onChanged(path);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Não foi possível salvar a foto.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.photoPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (path != null)
          Image.file(
            File(path),
            height: 96,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                const Text('Foto indisponível no aparelho.'),
          ),
        Wrap(
          children: [
            TextButton.icon(
              onPressed: widget.enabled && !_busy ? _choose : null,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(path == null ? 'Adicionar foto' : 'Trocar foto'),
            ),
            if (path != null)
              TextButton(
                onPressed: widget.enabled && !_busy
                    ? () => widget.onChanged(null)
                    : null,
                child: const Text('Remover foto'),
              ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error case final String error)
          Text(error,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}
