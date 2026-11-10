import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WeatherLocation {
  const WeatherLocation({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.region,
    this.country,
  });

  final String name;
  final double latitude;
  final double longitude;
  final String? region;
  final String? country;

  String get label => [name, region, country]
      .where((value) => value != null && value.isNotEmpty)
      .join(', ');

  Map<String, dynamic> toJson() => {
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'region': region,
        'country': country,
      };

  factory WeatherLocation.fromJson(Map<String, dynamic> json) =>
      WeatherLocation(
        name: json['name'] as String? ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        region: json['admin1'] as String? ?? json['region'] as String?,
        country: json['country'] as String?,
      );
}

class WeatherDay {
  const WeatherDay({
    required this.date,
    required this.code,
    required this.maxC,
    required this.minC,
    required this.rainMm,
    required this.rainChance,
    required this.uvMax,
    required this.maxWindKmh,
  });

  final DateTime date;
  final int code;
  final double maxC;
  final double minC;
  final double rainMm;
  final int rainChance;
  final double uvMax;
  final double maxWindKmh;
}

class WeatherHour {
  const WeatherHour({
    required this.date,
    required this.code,
    required this.temperatureC,
    required this.rainMm,
    required this.rainChance,
    required this.windKmh,
  });

  final DateTime date;
  final int code;
  final double temperatureC;
  final double rainMm;
  final int rainChance;
  final double windKmh;
}

class WeatherSnapshot {
  const WeatherSnapshot({
    required this.fetchedAt,
    required this.temperatureC,
    required this.apparentC,
    required this.humidity,
    required this.windKmh,
    required this.precipitationMm,
    required this.code,
    required this.days,
    required this.hours,
  });

  final DateTime fetchedAt;
  final double temperatureC;
  final double apparentC;
  final int humidity;
  final double windKmh;
  final double precipitationMm;
  final int code;
  final List<WeatherDay> days;
  final List<WeatherHour> hours;

  factory WeatherSnapshot.fromJson(Map<String, dynamic> json) {
    final current = Map<String, dynamic>.from(json['current'] as Map);
    final daily = Map<String, dynamic>.from(json['daily'] as Map);
    final hourly = Map<String, dynamic>.from(json['hourly'] as Map);
    final times = daily['time'] as List<dynamic>;
    final codes = daily['weather_code'] as List<dynamic>;
    final highs = daily['temperature_2m_max'] as List<dynamic>;
    final lows = daily['temperature_2m_min'] as List<dynamic>;
    final rains = daily['precipitation_sum'] as List<dynamic>;
    final chances = daily['precipitation_probability_max'] as List<dynamic>;
    final uv = daily['uv_index_max'] as List<dynamic>;
    final winds = daily['wind_speed_10m_max'] as List<dynamic>;
    double number(dynamic value) => (value as num?)?.toDouble() ?? 0;
    final hourTimes = hourly['time'] as List<dynamic>? ?? const [];
    final hourCodes = hourly['weather_code'] as List<dynamic>? ?? const [];
    final hourTemperatures =
        hourly['temperature_2m'] as List<dynamic>? ?? const [];
    final hourRains = hourly['precipitation'] as List<dynamic>? ?? const [];
    final hourChances =
        hourly['precipitation_probability'] as List<dynamic>? ?? const [];
    final hourWinds = hourly['wind_speed_10m'] as List<dynamic>? ?? const [];
    return WeatherSnapshot(
      fetchedAt:
          DateTime.tryParse(current['time'] as String? ?? '') ?? DateTime.now(),
      temperatureC: number(current['temperature_2m']),
      apparentC: number(current['apparent_temperature']),
      humidity: number(current['relative_humidity_2m']).round(),
      windKmh: number(current['wind_speed_10m']),
      precipitationMm: number(current['precipitation']),
      code: number(current['weather_code']).round(),
      days: List.generate(
          times.length,
          (index) => WeatherDay(
                date: DateTime.parse(times[index] as String),
                code: number(codes[index]).round(),
                maxC: number(highs[index]),
                minC: number(lows[index]),
                rainMm: number(rains[index]),
                rainChance: number(chances[index]).round(),
                uvMax: number(uv[index]),
                maxWindKmh: number(winds[index]),
              )),
      hours: List.generate(
          hourTimes.length,
          (index) => WeatherHour(
                date: DateTime.parse(hourTimes[index] as String),
                code: number(index < hourCodes.length ? hourCodes[index] : null)
                    .round(),
                temperatureC: number(index < hourTemperatures.length
                    ? hourTemperatures[index]
                    : null),
                rainMm:
                    number(index < hourRains.length ? hourRains[index] : null),
                rainChance: number(
                        index < hourChances.length ? hourChances[index] : null)
                    .round(),
                windKmh:
                    number(index < hourWinds.length ? hourWinds[index] : null),
              )),
    );
  }
}

class WeatherService {
  WeatherService._();
  static final WeatherService instance = WeatherService._();

  static const _locationKey = 'agro_weather_location_v1';
  static const _forecastKey = 'agro_weather_forecast_v1';
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));

  Future<WeatherLocation?> loadLocation() async {
    final raw = (await SharedPreferences.getInstance()).getString(_locationKey);
    if (raw == null) return null;
    try {
      return WeatherLocation.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLocation(WeatherLocation location) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_locationKey, jsonEncode(location.toJson()));
  }

  Future<List<WeatherLocation>> searchLocations(String query) async {
    final response = await _dio.get<Map<String, dynamic>>(
      'https://geocoding-api.open-meteo.com/v1/search',
      queryParameters: {
        'name': query.trim(),
        'count': 10,
        'language': 'pt',
        'format': 'json',
        'countryCode': 'BR',
      },
    );
    final rows = response.data?['results'] as List<dynamic>? ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => WeatherLocation.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<WeatherSnapshot> forecast(WeatherLocation location) async {
    final response = await _dio.get<Map<String, dynamic>>(
      'https://api.open-meteo.com/v1/forecast',
      queryParameters: {
        'latitude': location.latitude,
        'longitude': location.longitude,
        'current':
            'temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m',
        'daily':
            'weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,uv_index_max,wind_speed_10m_max',
        'hourly':
            'temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m',
        'forecast_hours': 24,
        'forecast_days': 7,
        'timezone': 'auto',
        'temperature_unit': 'celsius',
        'wind_speed_unit': 'kmh',
      },
    );
    final result = WeatherSnapshot.fromJson(response.data!);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _forecastKey, _encodeForecast(location, response.data!));
    return result;
  }

  Future<(WeatherLocation, WeatherSnapshot)?> loadCachedForecast() async {
    final raw = (await SharedPreferences.getInstance()).getString(_forecastKey);
    if (raw == null) return null;
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return (
        WeatherLocation.fromJson(
            Map<String, dynamic>.from(decoded['location'] as Map)),
        WeatherSnapshot.fromJson(
            Map<String, dynamic>.from(decoded['forecast'] as Map)),
      );
    } catch (_) {
      return null;
    }
  }

  String _encodeForecast(WeatherLocation location, Map<String, dynamic> data) {
    final payload = <String, dynamic>{
      'location': location.toJson(),
      'forecast': data
    };
    return jsonEncode(payload);
  }
}
