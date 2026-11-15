class RuralClient {
  const RuralClient(
      {required this.id,
      required this.name,
      required this.document,
      required this.phone,
      required this.address,
      required this.properties});
  final String id, name, document, phone, address;
  final List<RuralProperty> properties;
  RuralClient copyWith(
          {String? name,
          String? document,
          String? phone,
          String? address,
          List<RuralProperty>? properties}) =>
      RuralClient(
          id: id,
          name: name ?? this.name,
          document: document ?? this.document,
          phone: phone ?? this.phone,
          address: address ?? this.address,
          properties: properties ?? this.properties);
  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'document': document,
        'phone': phone,
        'address': address,
        'properties': properties.map((x) => x.toJson()).toList()
      };
  factory RuralClient.fromJson(Map<String, dynamic> j) => RuralClient(
      id: j['id'] as String,
      name: j['name'] as String,
      document: j['document'] as String? ?? '',
      phone: j['phone'] as String? ?? '',
      address: j['address'] as String? ?? '',
      properties: (j['properties'] as List<dynamic>? ?? [])
          .map((x) => RuralProperty.fromJson(x as Map<String, dynamic>))
          .toList());
}

class RuralProperty {
  const RuralProperty(
      {required this.id,
      required this.name,
      required this.location,
      required this.totalArea,
      required this.fields});
  final String id, name, location;
  final double totalArea;
  final List<RuralField> fields;
  RuralProperty copyWith(
          {String? name,
          String? location,
          double? totalArea,
          List<RuralField>? fields}) =>
      RuralProperty(
          id: id,
          name: name ?? this.name,
          location: location ?? this.location,
          totalArea: totalArea ?? this.totalArea,
          fields: fields ?? this.fields);
  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'location': location,
        'totalArea': totalArea,
        'fields': fields.map((x) => x.toJson()).toList()
      };
  factory RuralProperty.fromJson(Map<String, dynamic> j) => RuralProperty(
      id: j['id'] as String,
      name: j['name'] as String,
      location: j['location'] as String? ?? '',
      totalArea: (j['totalArea'] as num?)?.toDouble() ?? 0,
      fields: (j['fields'] as List<dynamic>? ?? [])
          .map((x) => RuralField.fromJson(x as Map<String, dynamic>))
          .toList());
}

class RuralField {
  const RuralField(
      {required this.id,
      required this.name,
      required this.area,
      required this.crop,
      required this.notes});
  final String id, name, crop, notes;
  final double area;
  Map<String, Object> toJson() =>
      {'id': id, 'name': name, 'area': area, 'crop': crop, 'notes': notes};
  factory RuralField.fromJson(Map<String, dynamic> j) => RuralField(
      id: j['id'] as String,
      name: j['name'] as String,
      area: (j['area'] as num).toDouble(),
      crop: j['crop'] as String? ?? '',
      notes: j['notes'] as String? ?? '');
}
