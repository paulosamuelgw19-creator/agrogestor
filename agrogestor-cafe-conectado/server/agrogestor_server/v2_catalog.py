"""Property/plot edits preserve identity and retain versioned snapshots."""
from . import commercial
from decimal import Decimal
from uuid import UUID
from fastapi import HTTPException
from .management_schema import set_responsible
from .v2_models import PropertyUpdateBody, PlotUpdateBody


def ensure_active(prop, plot=None):
    if prop['archived'] or (plot is not None and plot['archived']):
        raise HTTPException(409, 'Propriedade ou talhão arquivado. Reative o cadastro antes de novos lançamentos.')


def validate_area(db, tenant, property_id, area, *, plot_id=None, property_edit=False):
    prop = db.execute('SELECT * FROM v2_properties WHERE tenant_id=? AND id=?', (tenant, str(property_id))).fetchone()
    rows = db.execute('SELECT id,area_ha FROM v2_plots WHERE tenant_id=? AND property_id=? AND archived=0',
                      (tenant, str(property_id))).fetchall()
    known = sum((Decimal(r['area_ha']) for r in rows
                 if r['area_ha'] is not None and (property_edit or r['id'] != str(plot_id))), Decimal(0))
    total = area if property_edit else (Decimal(prop['area_ha']) if prop['area_ha'] is not None else None)
    used = known if property_edit else known + (area or Decimal(0))
    if total is not None and used > total:
        raise HTTPException(422, 'A soma das áreas conhecidas dos talhões ativos excede a área da propriedade.')


def record_revision(db, api, user, entity, row, provenance):
    import json
    db.execute('INSERT OR IGNORE INTO v2_catalog_revisions VALUES(?,?,?,?,?,?,?,?)',
        (user['farmId'], entity, row['id'], row['version'],
         json.dumps(dict(row), ensure_ascii=False, sort_keys=True), user['id'], api.utc_now(), provenance))


def install_catalog_routes(router, api, User, *, get, access, admin, write, replay, remember, audit):
    @router.patch('/properties/{property_id}')
    def edit_property(property_id: UUID, body: PropertyUpdateBody, user: User):
        admin(user)
        with write(user) as db:
            current = get(db, 'v2_properties', user['farmId'], property_id)
            entity = 'property-update:' + str(property_id)
            if replay(db, user, entity, body):
                return dict(current)
            if current['version'] != body.expected_version:
                raise HTTPException(409, 'A propriedade mudou. Atualize antes de salvar.')
            if current['archived'] and not body.archived:
                commercial.write_access(db,user['farmId'],'properties')
                commercial.ensure_slot(db,user['farmId'],'properties')
            validate_area(db, user['farmId'], property_id, body.area_ha, property_edit=True)
            record_revision(db, api, user, 'property', current, 'captured-before-edit')
            db.execute('''UPDATE v2_properties SET name=?,area_ha=?,location=?,notes=?,archived=?,version=version+1
              WHERE tenant_id=? AND id=?''', (body.name, str(body.area_ha) if body.area_ha is not None else None,
              body.location, body.notes, int(body.archived), user['farmId'], str(property_id)))
            if 'responsible_user_id' in body.model_fields_set:
                set_responsible(db, user, property_id, body.responsible_user_id)
            updated = get(db, 'v2_properties', user['farmId'], property_id)
            record_revision(db, api, user, 'property', updated, 'edit')
            remember(db, user, entity, body)
            audit(db, user, 'archive' if body.archived else 'update', 'property', property_id, body,
                  property_id, dict(current))
            return dict(updated)

    @router.patch('/plots/{plot_id}')
    def edit_plot(plot_id: UUID, body: PlotUpdateBody, user: User):
        admin(user)
        with write(user) as db:
            current = get(db, 'v2_plots', user['farmId'], plot_id)
            entity = 'plot-update:' + str(plot_id)
            if replay(db, user, entity, body):
                return dict(current)
            if current['version'] != body.expected_version:
                raise HTTPException(409, 'O talhão mudou. Atualize antes de salvar.')
            prop = get(db, 'v2_properties', user['farmId'], current['property_id'])
            if not body.archived:
                ensure_active(prop)
                validate_area(db, user['farmId'], current['property_id'], body.area_ha, plot_id=plot_id)
            record_revision(db, api, user, 'plot', current, 'captured-before-edit')
            db.execute('''UPDATE v2_plots SET name=?,area_ha=?,notes=?,archived=?,version=version+1
              WHERE tenant_id=? AND id=?''', (body.name, str(body.area_ha) if body.area_ha is not None else None,
              body.notes, int(body.archived), user['farmId'], str(plot_id)))
            updated = get(db, 'v2_plots', user['farmId'], plot_id)
            record_revision(db, api, user, 'plot', updated, 'edit')
            remember(db, user, entity, body)
            audit(db, user, 'archive' if body.archived else 'update', 'plot', plot_id, body,
                  current['property_id'], dict(current))
            return dict(updated)
