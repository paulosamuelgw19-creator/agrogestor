"""Measured output, with explicit units. Never infer production from worked area."""
from decimal import Decimal, localcontext
from .v2_metrics import decimal_text, metric, ratio

STATEMENTS = [
    '''CREATE TABLE v2_harvest_outputs (
      tenant_id TEXT NOT NULL, operation_id TEXT NOT NULL, quantity TEXT NOT NULL,
      unit TEXT NOT NULL, kg_per_unit TEXT,
      PRIMARY KEY(tenant_id,operation_id),
      FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id))''',
]


def persist(db, tenant, operation_id, output):
    if output is not None:
        db.execute('INSERT INTO v2_harvest_outputs VALUES(?,?,?,?,?)',
                   (tenant,str(operation_id),decimal_text(output.quantity),output.unit,decimal_text(output.kg_per_unit)))


def report(operations, cycles, plots):
    with localcontext() as arithmetic:
        arithmetic.prec = 50
        return _report(operations,cycles,plots)


def _report(operations, cycles, plots):
    result = []
    for cycle in cycles:
        selected = [o for o in operations if o['cycle_id']==cycle['id'] and o['kind']=='harvest']
        if not selected: continue
        plot = plots[cycle['plot_id']]
        outputs = [o['harvest_output'] for o in selected if o.get('harvest_output') is not None]
        # Missing output is unknown, including an older harvest with no quantity.
        kg = []
        for operation in selected:
            output = operation.get('harvest_output')
            if output is None:
                kg.append(None); continue
            weight = {'kg':'1','t':'1000'}.get(output['unit']) or output['kg_per_unit']
            kg.append(Decimal(output['quantity'])*Decimal(weight) if weight is not None else None)
        total = metric(kg,'kg')
        area = cycle['area_ha']  # Do not substitute current plot area for historical season area.
        result.append({'cycle_id':cycle['id'],'cycle_name':cycle['name'],'plot_id':plot['id'],
          'plot_name':plot['name'],'property_id':plot['property_id'],'registered_cycle_area_ha':area,
          'production_kg':total,'production_per_registered_ha':ratio(total,area,'kg/ha'),
          'quantities_by_unit':[{'unit':unit,'quantity':decimal_text(sum(Decimal(o['quantity']) for o in outputs if o['unit']==unit))}
                                for unit in sorted({o['unit'] for o in outputs})],
          'missing_outputs':len(selected)-len(outputs),
          'operation_ids':[o['id'] for o in selected],
          'scope':'Produção registrada no período / área cadastrada do ciclo; não representa rendimento final de safra incompleta. Sacas/caixas sem peso não são convertidas para kg.'})
    return result
