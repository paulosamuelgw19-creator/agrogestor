import 'package:flutter/material.dart';

/// Equal-width cards that reflow instead of shrinking readable text.
class ResponsiveSummary extends StatelessWidget {
  const ResponsiveSummary({super.key, required this.values});
  final List<({String label, int value})> values;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final capacity = (box.maxWidth / (144 * textScale)).floor();
        // Four indicators form balanced rows, including medium-width phones.
        final columns = capacity >= 4
            ? 4
            : capacity >= 2
                ? 2
                : 1;
        return Column(children: [
          for (var start = 0; start < values.length; start += columns)
            Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: IntrinsicHeight(
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      for (var column = 0; column < columns; column++) ...[
                        if (column > 0) const SizedBox(width: 8),
                        Expanded(
                            child: start + column >= values.length
                                ? const SizedBox.shrink()
                                : Card(
                                    margin: EdgeInsets.zero,
                                    child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.start,
                                            children: [
                                              Text(
                                                  '${values[start + column].value}',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .headlineMedium
                                                      ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                              const SizedBox(height: 4),
                                              Text(values[start + column].label,
                                                  textAlign: TextAlign.center)
                                            ]))))
                      ]
                    ])))
        ]);
      });
}
