import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'weather_service.dart';

class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  WeatherLocation? _location;
  WeatherSnapshot? _weather;
  bool _loading = true;
  bool _offlineData = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final saved = await WeatherService.instance.loadLocation();
    if (saved != null) {
      _location = saved;
      await _refresh(saved, showLoading: false);
    } else {
      final cached = await WeatherService.instance.loadCachedForecast();
      if (mounted) {
        setState(() {
          _location = cached?.$1;
          _weather = cached?.$2;
          _offlineData = cached != null;
          _loading = false;
        });
      }
    }
  }

  Future<void> _refresh(WeatherLocation location,
      {bool showLoading = true}) async {
    if (showLoading && mounted) setState(() => _loading = true);
    try {
      final result = await WeatherService.instance.forecast(location);
      if (!mounted) return;
      setState(() {
        _location = location;
        _weather = result;
        _offlineData = false;
        _error = null;
        _loading = false;
      });
    } on DioException {
      final saved = await WeatherService.instance.loadCachedForecast();
      final cached = saved != null &&
              (saved.$1.latitude - location.latitude).abs() < 0.001 &&
              (saved.$1.longitude - location.longitude).abs() < 0.001
          ? saved
          : null;
      if (!mounted) return;
      setState(() {
        _location = location;
        _weather = cached?.$2;
        _offlineData = cached != null;
        _error = cached == null
            ? 'Não foi possível consultar a previsão. Verifique a internet e tente novamente.'
            : 'Sem conexão. Exibindo a última previsão salva neste aparelho.';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Não foi possível carregar os dados do clima.';
        _loading = false;
      });
    }
  }

  Future<void> _chooseLocation() async {
    final controller = TextEditingController(text: _location?.name ?? '');
    List<WeatherLocation> results = [];
    String? error;
    bool searching = false;
    final selected = await showDialog<WeatherLocation>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> search() async {
            if (controller.text.trim().length < 2) {
              setDialogState(() => error = 'Digite pelo menos duas letras.');
              return;
            }
            setDialogState(() {
              searching = true;
              error = null;
            });
            try {
              final found = await WeatherService.instance
                  .searchLocations(controller.text);
              if (!dialogContext.mounted) return;
              setDialogState(() {
                results = found;
                searching = false;
                if (found.isEmpty) error = 'Nenhum local encontrado.';
              });
            } catch (_) {
              if (!dialogContext.mounted) return;
              setDialogState(() {
                searching = false;
                error =
                    'Falha ao buscar local. Confira a conexão com a internet.';
              });
            }
          }

          return AlertDialog(
            title: const Text('Local da fazenda'),
            content: SizedBox(
              width: AppTheme.dialogWidth(context, maxWidth: 440),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => search(),
                  decoration: InputDecoration(
                    labelText: 'Cidade ou município',
                    hintText: 'Ex.: Ribeirão Preto',
                    suffixIcon: IconButton(
                      tooltip: 'Buscar',
                      onPressed: search,
                      icon: searching
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.search),
                    ),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                if (results.isNotEmpty)
                  SizedBox(
                    height: 260,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final item = results[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.location_on_outlined),
                          title: Text(item.name),
                          subtitle: Text([item.region, item.country]
                              .whereType<String>()
                              .where((part) => part.isNotEmpty)
                              .join(' · ')),
                          onTap: () => Navigator.pop(dialogContext, item),
                        );
                      },
                    ),
                  ),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancelar')),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (selected == null || !mounted) return;
    await WeatherService.instance.saveLocation(selected);
    setState(() => _location = selected);
    await _refresh(selected);
  }

  String _condition(int code) => switch (code) {
        0 => 'Céu limpo',
        1 => 'Predominantemente limpo',
        2 => 'Parcialmente nublado',
        3 => 'Nublado',
        45 || 48 => 'Nevoeiro',
        51 || 53 || 55 => 'Garoa',
        56 || 57 => 'Garoa congelante',
        61 || 63 || 65 => 'Chuva',
        66 || 67 => 'Chuva congelante',
        71 || 73 || 75 || 77 => 'Neve',
        80 || 81 || 82 => 'Pancadas de chuva',
        85 || 86 => 'Pancadas de neve',
        95 || 96 || 99 => 'Trovoadas',
        _ => 'Condição variável',
      };

  IconData _weatherIcon(int code) => switch (code) {
        0 || 1 => Icons.wb_sunny_outlined,
        2 || 3 || 45 || 48 => Icons.cloud_outlined,
        51 ||
        53 ||
        55 ||
        56 ||
        57 ||
        61 ||
        63 ||
        65 ||
        66 ||
        67 ||
        80 ||
        81 ||
        82 =>
          Icons.water_drop_outlined,
        95 || 96 || 99 => Icons.thunderstorm_outlined,
        _ => Icons.cloud_queue_outlined,
      };

  String _weekday(DateTime date) {
    const names = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];
    return names[date.weekday - 1];
  }

  @override
  Widget build(BuildContext context) {
    final location = _location;
    final weather = _weather;
    return RefreshIndicator(
      onRefresh: () async {
        if (location != null) await _refresh(location);
      },
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Clima da fazenda',
                        style: Theme.of(context).textTheme.headlineSmall),
                    Text(location?.label ?? 'Escolha o município da fazenda',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ]),
            ),
            IconButton.filledTonal(
              tooltip: 'Escolher local',
              onPressed: _chooseLocation,
              icon: const Icon(Icons.location_on_outlined),
            ),
            if (location != null)
              IconButton(
                tooltip: 'Atualizar previsão',
                onPressed: _loading ? null : () => _refresh(location),
                icon: const Icon(Icons.refresh),
              ),
          ]),
          const SizedBox(height: 14),
          if (_error != null)
            Card(
              color: _offlineData ? Colors.amber.shade50 : Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_error!),
              ),
            ),
          if (_loading && weather != null) const LinearProgressIndicator(),
          if (_loading && weather == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 56),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (weather == null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(children: [
                  const Icon(Icons.cloud_outlined,
                      size: 50, color: AppTheme.primary),
                  const SizedBox(height: 12),
                  const Text('Veja as condições e a previsão da região.'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _chooseLocation,
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Selecionar município'),
                  ),
                ]),
              ),
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(_weatherIcon(weather.code),
                            size: 44, color: AppTheme.primary),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_condition(weather.code),
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                Text('Atualizado ${_time(weather.fetchedAt)}'),
                              ]),
                        ),
                        Text('${weather.temperatureC.round()}°',
                            style: Theme.of(context)
                                .textTheme
                                .displaySmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ]),
                      const Divider(height: 28),
                      Wrap(
                        spacing: 18,
                        runSpacing: 12,
                        children: [
                          _metric(Icons.thermostat, 'Sensação',
                              '${weather.apparentC.round()}°C'),
                          _metric(Icons.water_drop_outlined, 'Umidade',
                              '${weather.humidity}%'),
                          _metric(Icons.air, 'Vento',
                              '${weather.windKmh.round()} km/h'),
                          _metric(Icons.umbrella_outlined, 'Chuva agora',
                              '${weather.precipitationMm.toStringAsFixed(1)} mm'),
                        ],
                      ),
                    ]),
              ),
            ),
            const SizedBox(height: 12),
            _hourlyForecast(weather.hours),
            const SizedBox(height: 12),
            _fieldAlerts(weather.days),
            const SizedBox(height: 12),
            Text('Próximos 7 dias',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            ...weather.days.map((day) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          SizedBox(
                            width: 44,
                            child: Text(_weekday(day.date),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ),
                          Icon(_weatherIcon(day.code), color: AppTheme.primary),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_condition(day.code))),
                          Text('${day.minC.round()}° / ${day.maxC.round()}°'),
                        ]),
                        const SizedBox(height: 8),
                        Semantics(
                          label: 'Chuva: ${day.rainMm.toStringAsFixed(1)} '
                              'milímetros, ${day.rainChance}% de probabilidade',
                          child: ExcludeSemantics(
                            child: Row(children: [
                              const Icon(Icons.water_drop_outlined,
                                  size: 16, color: AppTheme.primary),
                              const SizedBox(width: 6),
                              Text('${day.rainMm.toStringAsFixed(1)} mm'),
                              const SizedBox(width: 12),
                              Text('${day.rainChance}% de chance de chuva'),
                            ]),
                          ),
                        ),
                      ],
                    ),
                  ),
                )),
            const SizedBox(height: 10),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Previsões são estimativas e podem mudar. As orientações são alertas gerais, não substituem avaliação agronômica nem as condições observadas na fazenda. Confirme as condições locais antes de decidir sobre operações ou irrigação.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 14),
              child: Text('Fonte meteorológica: Open-Meteo · dados CC BY 4.0',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String label, String value) => SizedBox(
        width: 132,
        child: Row(children: [
          Icon(icon, size: 20, color: AppTheme.primary),
          const SizedBox(width: 7),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 11)),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
      );

  String _time(DateTime date) =>
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

  Widget _hourlyForecast(List<WeatherHour> hours) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Próximas 24 horas', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      if (hours.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Text('Previsão por hora indisponível para este local.'),
          ),
        )
      else
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: hours.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final hour = hours[index];
              return Semantics(
                label:
                    '${_time(hour.date)}, ${hour.temperatureC.round()} graus, '
                    '${hour.rainChance}% de chance de chuva, '
                    '${hour.rainMm.toStringAsFixed(1)} milímetros',
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 92,
                    child: Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 10),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_time(hour.date),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            Icon(_weatherIcon(hour.code),
                                color: AppTheme.primary, size: 22),
                            Text('${hour.temperatureC.round()}°C'),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.water_drop_outlined,
                                    size: 14, color: AppTheme.primary),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text('${hour.rainChance}%',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12)),
                                ),
                              ],
                            ),
                            Text('${hour.rainMm.toStringAsFixed(1)} mm',
                                style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
    ]);
  }

  Widget _fieldAlerts(List<WeatherDay> days) {
    final alerts = <({String title, String detail, IconData icon})>[];
    final rainy = days
        .where((day) => day.rainMm >= 10 || day.rainChance >= 75)
        .firstOrNull;
    if (rainy != null) {
      alerts.add((
        title: 'Chuva prevista',
        detail:
            '${_weekday(rainy.date)}: ${rainy.rainMm.round()} mm e ${rainy.rainChance}% de chance. Planeje pulverizações e deslocamentos.',
        icon: Icons.umbrella_outlined
      ));
    }
    final windy = days.where((day) => day.maxWindKmh >= 45).firstOrNull;
    if (windy != null) {
      alerts.add((
        title: 'Vento forte',
        detail:
            '${_weekday(windy.date)} pode chegar a ${windy.maxWindKmh.round()} km/h. Confira as condições antes de pulverizar.',
        icon: Icons.air
      ));
    }
    final hot = days.where((day) => day.maxC >= 35).firstOrNull;
    if (hot != null) {
      alerts.add((
        title: 'Temperatura elevada',
        detail:
            '${_weekday(hot.date)} pode atingir ${hot.maxC.round()}°. Considere o manejo de irrigação e o bem-estar da equipe.',
        icon: Icons.wb_sunny_outlined
      ));
    }
    final cold = days.where((day) => day.minC <= 5).firstOrNull;
    if (cold != null) {
      alerts.add((
        title: 'Temperatura baixa',
        detail:
            '${_weekday(cold.date)} pode ter mínima de ${cold.minC.round()}°. Avalie culturas sensíveis e animais.',
        icon: Icons.ac_unit_outlined
      ));
    }
    final highUv = days.where((day) => day.uvMax >= 8).firstOrNull;
    if (highUv != null) {
      alerts.add((
        title: 'Índice UV muito alto',
        detail:
            '${_weekday(highUv.date)}: UV máximo previsto de ${highUv.uvMax.round()}. Reforce proteção solar para equipes em campo.',
        icon: Icons.wb_sunny_outlined
      ));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Atenção no campo',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          if (alerts.isEmpty)
            const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.check_circle_outline, color: AppTheme.leaf),
                title: Text('Sem alertas de manejo'),
                subtitle: Text(
                    'A previsão consultada não indica os alertas monitorados. Isso não garante condições ideais de operação.'))
          else
            for (final alert in alerts.take(4))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(alert.icon, color: AppTheme.leaf),
                title: Text(alert.title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(alert.detail),
              ),
        ]),
      ),
    );
  }
}
