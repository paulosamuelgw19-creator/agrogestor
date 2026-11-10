"""Versioned farm boundaries. No device location or employee tracking."""
import json
import re
from typing import Literal
from uuid import UUID
from fastapi import HTTPException
from geographiclib.geodesic import Geodesic
from pydantic import Field, model_validator
from shapely.geometry import Polygon
from . import commercial
from .v2_models import Body, Name

STATEMENTS = [
    '''CREATE TABLE v2_boundaries (
      tenant_id TEXT NOT NULL, property_id TEXT NOT NULL, target_kind TEXT NOT NULL,
      target_id TEXT NOT NULL, points_json TEXT NOT NULL, area_ha TEXT,
      color TEXT NOT NULL, version INTEGER NOT NULL, deleted INTEGER NOT NULL,
      actor_id TEXT NOT NULL, updated_at TEXT NOT NULL,
      PRIMARY KEY(tenant_id,target_kind,target_id),
      FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id))''',
]


class BoundaryBody(Body):
    id: UUID
    expected_version: int = Field(strict=True, ge=0)
    points: list[tuple[float, float]] = Field(default_factory=list, max_length=500)
    color: str = '#26734D'
    deleted: bool = Field(default=False, strict=True)
    reason: Name

    @model_validator(mode='after')
    def valid(self):
        if not re.fullmatch(r'#[0-9a-fA-F]{6}', self.color):
            raise ValueError('Cor inválida.')
        if self.deleted:
            if self.points:
                raise ValueError('A remoção não recebe novas coordenadas.')
        else:
            validate_polygon(self.points)
        return self


def validate_polygon(points):
    """Local agricultural extents; reject ambiguous dateline/polar geometry."""
    points = [tuple(p) for p in points]
    if len(points) < 3 or any(not (-180 <= x <= 180 and -85 <= y <= 85) for x,y in points):
        raise ValueError('Informe ao menos três coordenadas válidas (longitude, latitude).')
    if len(set(points)) < 3 or len(set(points[:-1] if points[0] == points[-1] else points)) != len(points[:-1] if points[0] == points[-1] else points):
        raise ValueError('Não repita vértices da demarcação.')
    if max(x for x,y in points)-min(x for x,y in points) > 5 or max(y for x,y in points)-min(y for x,y in points) > 5:
        raise ValueError('Demarcação extensa demais; utilize limites locais de até cinco graus.')
    polygon = Polygon(points)
    if not polygon.is_valid or polygon.area <= 1e-16:
        raise ValueError('Polígono inválido: verifique cruzamentos e vértices alinhados.')
    return polygon


def area_ha(points):
    polygon = Geodesic.WGS84.Polygon()
    for lon, lat in points:
        polygon.AddPoint(lat, lon)
    return f'{abs(polygon.Compute()[2])/10000:.6f}'


def install(router, api, User, *, get, access, write, replay, remember, audit, operation_detail):
    def target(db, user, kind, identity):
        record = get(db, 'v2_properties' if kind == 'property' else 'v2_plots', user['farmId'], identity)
        property_id = str(identity) if kind == 'property' else record['property_id']
        access(db, user, property_id)
        return record, property_id

    def encode(row):
        value = dict(row)
        value['points'] = json.loads(value.pop('points_json'))
        value['area_method'] = 'WGS84_geodesic_estimate'
        return value

    @router.get('/properties/{property_id}/map')
    def read_map(property_id: UUID, user: User):
        with api.connect() as db:
            role = access(db, user, property_id)
            prop = dict(get(db, 'v2_properties', user['farmId'], property_id))
            plots = [dict(r) for r in db.execute('SELECT * FROM v2_plots WHERE tenant_id=? AND property_id=? ORDER BY name', (user['farmId'], str(property_id)))]
            boundaries = [encode(r) for r in db.execute('SELECT * FROM v2_boundaries WHERE tenant_id=? AND property_id=?', (user['farmId'], str(property_id)))]
            can_edit = user['role'] in ('admin','operator') and role != 'consultant'
            try: commercial.write_access(db,user['farmId'],'properties')
            except commercial.CommercialError: can_edit = False
            return {'property': prop, 'plots': plots, 'boundaries': boundaries,
                    'administrator': user['role'] == 'admin', 'can_edit': can_edit,
                    'generated_at': api.utc_now(),
                    'notice': 'Áreas geodésicas estimadas; o cadastro em hectares não é alterado. Imagens de fundo exigem internet.'}

    @router.post('/maps/{kind}/{identity}')
    def save_boundary(kind: Literal['property','plot'], identity: UUID, body: BoundaryBody, user: User):
        if user['role'] not in ('admin','operator'):
            raise HTTPException(403, 'Somente gestor e operador podem demarcar.')
        with write(user) as db:
            commercial.write_access(db, user['farmId'], 'properties')
            record, property_id = target(db,user,kind,identity)
            access(db,user,property_id,'operate')
            entity = f'boundary:{kind}:{identity}'
            old = db.execute('SELECT * FROM v2_boundaries WHERE tenant_id=? AND target_kind=? AND target_id=?', (user['farmId'],kind,str(identity))).fetchone()
            if replay(db,user,entity,body):
                return encode(old)
            if body.expected_version != (old['version'] if old else 0):
                raise HTTPException(409, 'A demarcação mudou em outro aparelho. Revise o desenho antes de reenviar.')
            if body.deleted and not old:
                raise HTTPException(422, 'Não há demarcação para remover.')
            prop = get(db,'v2_properties',user['farmId'],property_id)
            if not body.deleted and (prop['archived'] or record['archived']):
                raise HTTPException(422, 'Reative o cadastro antes de demarcar.')
            if not body.deleted:
                polygon = validate_polygon(body.points)
                others = db.execute('SELECT * FROM v2_boundaries WHERE tenant_id=? AND property_id=? AND deleted=0', (user['farmId'],property_id)).fetchall()
                for other in others:
                    if other['target_kind'] == kind and other['target_id'] == str(identity): continue
                    other_polygon = validate_polygon(json.loads(other['points_json']))
                    if kind == 'plot' and other['target_kind'] == 'property' and not other_polygon.covers(polygon):
                        raise HTTPException(422, 'O talhão deve estar dentro da demarcação da fazenda.')
                    if kind == 'property' and other['target_kind'] == 'plot' and not polygon.covers(other_polygon):
                        raise HTTPException(422, 'A fazenda deve conter as demarcações dos talhões existentes.')
            version = (old['version'] if old else 0)+1
            db.execute('''INSERT INTO v2_boundaries VALUES(?,?,?,?,?,?,?,?,?,?,?)
              ON CONFLICT(tenant_id,target_kind,target_id) DO UPDATE SET points_json=excluded.points_json,
              area_ha=excluded.area_ha,color=excluded.color,version=excluded.version,deleted=excluded.deleted,
              actor_id=excluded.actor_id,updated_at=excluded.updated_at''',
              (user['farmId'],property_id,kind,str(identity),
               old['points_json'] if body.deleted else json.dumps(body.points),
               old['area_ha'] if body.deleted else area_ha(body.points),
               body.color,version,int(body.deleted),user['id'],api.utc_now()))
            remember(db,user,entity,body)
            result = encode(db.execute('SELECT * FROM v2_boundaries WHERE tenant_id=? AND target_kind=? AND target_id=?', (user['farmId'],kind,str(identity))).fetchone())
            audit(db,user,'remove-boundary' if body.deleted else 'save-boundary',kind,identity,result,property_id,encode(old) if old else None)
            return result

    @router.get('/plots/{plot_id}/operations')
    def plot_operations(plot_id: UUID, user: User):
        with api.connect() as db:
            _, property_id = target(db,user,'plot',plot_id)
            records = db.execute('''SELECT o.id FROM v2_operations o JOIN v2_cycles c
              ON c.tenant_id=o.tenant_id AND c.id=o.cycle_id WHERE o.tenant_id=? AND c.plot_id=?
              AND (?='admin' OR o.actor_id=?) ORDER BY o.performed_on DESC,o.created_at DESC''',
              (user['farmId'],str(plot_id),user['role'],user['id'])).fetchall()
            return {'property_id':property_id,'plot_id':str(plot_id),
                    'items':[operation_detail(db,user,r['id']) for r in records]}
