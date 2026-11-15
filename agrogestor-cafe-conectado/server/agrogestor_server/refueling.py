"""Refueling is a stock withdrawal or an external purchase, not measured burn."""
from decimal import Decimal, ROUND_FLOOR
from fastapi import HTTPException
from .v2_metrics import decimal_text, money_round


def is_fuel(item):
    kind = item['product_type'].strip().casefold()
    if kind in ('diesel', 'gasolina', 'etanol', 'combustível', 'combustivel'):
        return item['unit'] == 'L'
    # Preserve legacy products that have not yet been classified.
    return item['unit'] == 'L' and not kind and not item['category'] and item['name'].casefold().startswith(('diesel', 'gasolina', 'etanol'))


def validate_refuelings(db, tenant, property_id, body, get, machine_blocked):
    for refuel in body.refuelings:
        machine = get(db, 'v2_machines', tenant, refuel.machine_id)
        if machine['archived']:
            raise HTTPException(409,'Máquina arquivada. Reative antes de registrar abastecimento.')
        assigned = db.execute('SELECT 1 FROM v2_machine_properties WHERE tenant_id=? AND machine_id=? AND property_id=?',
          (tenant, str(refuel.machine_id), property_id)).fetchone()
        if not assigned:
            raise HTTPException(404, 'Máquina não vinculada a esta propriedade.')
        if machine_blocked(db, tenant, refuel.machine_id):
            raise HTTPException(409, 'Máquina parada para manutenção; aguarde a liberação da oficina.')
        use = next((m for m in body.machines if m.machine_id == refuel.machine_id), None)
        if use:
            if not use.start_meter <= refuel.hour_meter <= use.end_meter:
                raise HTTPException(422, 'Horímetro do abastecimento deve ficar entre o início e o fim do serviço da máquina.')
        elif refuel.hour_meter != Decimal(machine['hour_meter']):
            raise HTTPException(409, 'Sem apontamento de horas, use o horímetro confirmado da máquina. Registre o serviço para atualizar as horas.')
        latest = db.execute('SELECT MAX(occurred_on) FROM v2_refuelings WHERE tenant_id=? AND machine_id=?',
          (tenant, str(refuel.machine_id))).fetchone()[0]
        if latest and body.performed_on.isoformat() < latest:
            raise HTTPException(409, 'Abastecimento retroativo exige conferência do histórico da máquina.')
        if refuel.source == 'stock' and not is_fuel(get(db, 'v2_inputs', tenant, refuel.input_id)):
            raise HTTPException(422, 'Selecione um combustível cadastrado em litros: diesel, gasolina ou etanol.')


def store_refuelings(db, user, body, api):
    values = {}
    for input_id in {r.input_id for r in body.refuelings if r.source == 'stock'}:
        lines = [r for r in body.refuelings if r.input_id == input_id and r.source == 'stock']
        row = db.execute('SELECT value_cents FROM v2_inventory WHERE tenant_id=? AND operation_id=? AND input_id=? AND kind=\'consume\'',
          (user['farmId'], str(body.id), str(input_id))).fetchone()
        total = row[0]
        if total is None:
            values.update({r.id: None for r in lines})
            continue
        quantity = sum((r.liters for r in lines), Decimal(0))
        exact = [Decimal(total) * r.liters / quantity for r in lines]
        cents = [int(v.to_integral_value(rounding=ROUND_FLOOR)) for v in exact]
        remaining = total - sum(cents)
        order = sorted(range(len(lines)), key=lambda i: (-(exact[i] - cents[i]), i))
        for i in order[:remaining]: cents[i] += 1
        values.update({r.id: cents[i] for i, r in enumerate(lines)})
    for refuel in body.refuelings:
        cost = values[refuel.id] if refuel.source == 'stock' else None if refuel.unit_price_cents is None else money_round(refuel.liters * refuel.unit_price_cents)
        name = refuel.fuel_name
        if refuel.source == 'stock':
            name = db.execute('SELECT name FROM v2_inputs WHERE tenant_id=? AND id=?', (user['farmId'], str(refuel.input_id))).fetchone()[0]
        db.execute('INSERT INTO v2_refuelings VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          (user['farmId'], str(refuel.id), str(body.id), str(refuel.machine_id), refuel.source,
           str(refuel.input_id) if refuel.input_id else None, decimal_text(refuel.liters), decimal_text(refuel.hour_meter),
           refuel.unit_price_cents, cost, name, refuel.location, user['id'], body.performed_on.isoformat(), api.utc_now()))


def read_refuelings(db, user, operation_id, role):
    result = []
    for row in db.execute('SELECT r.*,m.name AS machine_name,u.display_name AS actor_name FROM v2_refuelings r '
      'JOIN v2_machines m ON m.tenant_id=r.tenant_id AND m.id=r.machine_id '
      'JOIN users u ON u.farm_id=r.tenant_id AND u.user_id=r.actor_id '
      'WHERE r.tenant_id=? AND r.operation_id=? ORDER BY r.rowid', (user['farmId'], str(operation_id))):
        item = dict(row)
        if role == 'employee':
            item.pop('unit_price_cents'); item.pop('total_cost_cents')
        result.append(item)
    return result
