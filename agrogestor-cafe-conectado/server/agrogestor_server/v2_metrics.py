"""Deterministic Decimal arithmetic; no AI or floating point in these totals."""
from decimal import Decimal, ROUND_HALF_UP, localcontext


def decimal_text(value):
    if value is None:
        return None
    with localcontext() as arithmetic:
        arithmetic.prec = 50
        return format(Decimal(value).normalize(), 'f')


def money_round(value):
    return int(Decimal(value).quantize(Decimal('1'), rounding=ROUND_HALF_UP))


def stock_balance(rows):
    if not rows or rows[0]['kind'] != 'opening':
        return {'known': False, 'quantity': None, 'value_cents': None}
    quantity, value = Decimal(0), 0
    for row in rows:
        amount = Decimal(row['quantity'])
        if row['kind'] in ('opening', 'receipt'):
            quantity += amount
            value = None if value is None or row['value_cents'] is None else value + row['value_cents']
        else:
            quantity -= amount
            value = None if value is None or row['value_cents'] is None else value - row['value_cents']
        if quantity < 0:
            raise ValueError('Movimentos de estoque inconsistentes: saldo negativo.')
        if quantity == 0:
            value = 0
    return {'known': True, 'quantity': quantity, 'value_cents': value}


def consumption_value(balance, quantity):
    quantity = Decimal(quantity)
    if not balance['known'] or quantity > balance['quantity']:
        raise ValueError('Estoque não conferido ou insuficiente.')
    if balance['value_cents'] is None:
        return None
    if quantity == balance['quantity']:
        return balance['value_cents']
    return money_round(Decimal(balance['value_cents']) * quantity / balance['quantity'])


def metric(values, unit):
    """An empty set is unknown, while an explicitly measured zero stays zero."""
    if not values:
        return {'status': 'no_data', 'value': None, 'known_subtotal': None, 'unit': unit,
                'records': 0, 'missing': 0}
    missing = sum(value is None for value in values)
    known = [Decimal(str(value)) for value in values if value is not None]
    with localcontext() as arithmetic:
        arithmetic.prec = 50
        subtotal = sum(known, Decimal(0)) if known else None
    return {'status': 'incomplete' if missing else 'complete_registered',
            'value': None if missing else decimal_text(subtotal),
            'known_subtotal': decimal_text(subtotal), 'unit': unit,
            'records': len(values), 'missing': missing}


def ratio(numerator, denominator, unit):
    if numerator['value'] is None or denominator is None or Decimal(denominator) <= 0:
        return {'status': 'unavailable', 'value': None, 'unit': unit}
    with localcontext() as arithmetic:
        arithmetic.prec = 50
        value = (Decimal(numerator['value']) / Decimal(denominator)).quantize(
            Decimal('0.000001'), rounding=ROUND_HALF_UP)
    return {'status': 'complete_registered', 'value': decimal_text(value), 'unit': unit}
