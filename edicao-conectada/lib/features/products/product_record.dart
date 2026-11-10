class FarmProduct {
  const FarmProduct(
      {required this.id,
      required this.name,
      required this.category,
      this.productType = '',
      required this.unit,
      required this.quantity,
      required this.lot});
  final String id, name, category, productType, unit, lot;
  final double quantity;
  FarmProduct copyWith(
          {String? name,
          String? category,
          String? productType,
          String? unit,
          double? quantity,
          String? lot}) =>
      FarmProduct(
          id: id,
          name: name ?? this.name,
          category: category ?? this.category,
          productType: productType ?? this.productType,
          unit: unit ?? this.unit,
          quantity: quantity ?? this.quantity,
          lot: lot ?? this.lot);
  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'productType': productType,
        'unit': unit,
        'quantity': quantity,
        'lot': lot
      };
  factory FarmProduct.fromJson(Map<String, dynamic> j) => FarmProduct(
      id: j['id'] as String,
      name: j['name'] as String,
      category: j['category'] as String? ?? '',
      productType: j['productType'] as String? ?? '',
      unit: j['unit'] as String? ?? 'un',
      quantity: (j['quantity'] as num).toDouble(),
      lot: j['lot'] as String? ?? '');
}

class ProductUsage {
  const ProductUsage(
      {required this.id,
      required this.productId,
      this.serviceId = '',
      required this.productName,
      required this.quantity,
      required this.unit,
      required this.date,
      required this.machine,
      required this.field,
      required this.operatorName});
  final String id,
      productId,
      serviceId,
      productName,
      unit,
      machine,
      field,
      operatorName;
  final double quantity;
  final DateTime date;
  Map<String, Object> toJson() => {
        'id': id,
        'productId': productId,
        'serviceId': serviceId,
        'productName': productName,
        'quantity': quantity,
        'unit': unit,
        'date': date.toIso8601String(),
        'machine': machine,
        'field': field,
        'operatorName': operatorName
      };
  factory ProductUsage.fromJson(Map<String, dynamic> j) => ProductUsage(
      id: j['id'] as String,
      productId: j['productId'] as String,
      serviceId: j['serviceId'] as String? ?? '',
      productName: j['productName'] as String,
      quantity: (j['quantity'] as num).toDouble(),
      unit: j['unit'] as String,
      date: DateTime.parse(j['date'] as String),
      machine: j['machine'] as String? ?? '',
      field: j['field'] as String? ?? '',
      operatorName: j['operatorName'] as String? ?? '');
}
