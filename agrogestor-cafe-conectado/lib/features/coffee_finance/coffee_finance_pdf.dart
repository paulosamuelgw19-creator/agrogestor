part of 'coffee_finance_screen.dart';

Future<({Uint8List bytes, String name})?> _selectFinancePdf() async {
  final file = await FilePicker.pickFile(
    dialogTitle: 'Escolher nota fiscal ou comprovante',
    type: FileType.custom,
    allowedExtensions: ['pdf'],
  );
  if (file == null) return null;
  final length = await file.length();
  if (length != null && length > coffeeAnalysisPdfMaxBytes) {
    throw const FormatException('O comprovante PDF excede 8 MB.');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    if (builder.length + chunk.length > coffeeAnalysisPdfMaxBytes) {
      throw const FormatException('O comprovante PDF excede 8 MB.');
    }
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  validateCoffeeAnalysisPdf(bytes);
  return (bytes: bytes, name: file.name);
}

Future<void> _openFinancePdf(BuildContext context, String path) async {
  try {
    FarmAccessPolicy.requireCoffeeManager();
    final bytes = await readCoffeeAnalysisPdf(File(path));
    if (!context.mounted) return;
    FarmAccessPolicy.requireCoffeeManager();
    await Navigator.push<void>(context,
        MaterialPageRoute(builder: (_) => _FinancePdfPreview(bytes: bytes)));
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Não foi possível abrir o comprovante no aparelho.')));
    }
  }
}

class _FinancePdfPreview extends StatelessWidget {
  const _FinancePdfPreview({required this.bytes});

  final Uint8List bytes;

  Future<void> _share(BuildContext context) async {
    try {
      FarmAccessPolicy.requireCoffeeManager();
      await Printing.sharePdf(bytes: bytes, filename: 'comprovante.pdf');
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Não foi possível compartilhar o comprovante.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Comprovante PDF'), actions: [
          IconButton(
              onPressed: () => _share(context),
              tooltip: 'Compartilhar PDF',
              icon: const Icon(Icons.share_outlined)),
        ]),
        body: SafeArea(
            child: PdfPreview(
          build: (_) => bytes,
          canChangeOrientation: false,
          canChangePageFormat: false,
          allowPrinting: false,
          allowSharing: false,
          useActions: false,
          onError: (context, _) => Center(
              child: TextButton(
                  onPressed: () => _share(context),
                  child: const Text('Prévia indisponível. Compartilhar PDF'))),
        )),
      );
}
