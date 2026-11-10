import 'package:agrogestao/features/weather/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WeatherSnapshot.fromJson', () {
    test('reads current conditions, seven days and hourly rain data', () {
      final snapshot = WeatherSnapshot.fromJson(_forecast());

      expect(snapshot.temperatureC, 27.5);
      expect(snapshot.humidity, 68);
      expect(snapshot.days, hasLength(7));
      expect(snapshot.days.first.rainMm, 12.4);
      expect(snapshot.days.first.rainChance, 80);
      expect(snapshot.hours, hasLength(2));
      expect(snapshot.hours.first.rainChance, 65);
      expect(snapshot.hours.first.rainMm, 1.2);
    });

    test('accepts missing hourly fields without failing the whole forecast',
        () {
      final forecast = _forecast();
      forecast['hourly'] = {
        'time': ['2026-10-12T12:00'],
      };

      final snapshot = WeatherSnapshot.fromJson(forecast);

      expect(snapshot.hours, hasLength(1));
      expect(snapshot.hours.single.temperatureC, 0);
      expect(snapshot.hours.single.rainChance, 0);
      expect(snapshot.hours.single.rainMm, 0);
    });
  });
}

Map<String, dynamic> _forecast() => {
      'current': {
        'time': '2026-10-12T12:00',
        'temperature_2m': 27.5,
        'apparent_temperature': 29.0,
        'relative_humidity_2m': 68,
        'wind_speed_10m': 12.0,
        'precipitation': 0.2,
        'weather_code': 2,
      },
      'daily': {
        'time': List.generate(
            7,
            (i) =>
                DateTime(2026, 10, 12 + i).toIso8601String().split('T').first),
        'weather_code': List.filled(7, 2),
        'temperature_2m_max': List.filled(7, 32.0),
        'temperature_2m_min': List.filled(7, 18.0),
        'precipitation_sum': [12.4, ...List.filled(6, 0.0)],
        'precipitation_probability_max': [80, ...List.filled(6, 10)],
        'uv_index_max': List.filled(7, 6.0),
        'wind_speed_10m_max': List.filled(7, 20.0),
      },
      'hourly': {
        'time': ['2026-10-12T12:00', '2026-10-12T13:00'],
        'weather_code': [2, 61],
        'temperature_2m': [27.5, 26.0],
        'precipitation': [1.2, 2.0],
        'precipitation_probability': [65, 90],
        'wind_speed_10m': [12.0, 14.0],
      },
    };
