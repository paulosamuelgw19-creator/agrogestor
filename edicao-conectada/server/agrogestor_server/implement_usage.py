"""Link the existing implement catalogue to immutable operation evidence."""
import json
from fastapi import HTTPException
from . import commercial

STATEMENTS = [
    '''CREATE TABLE v2_implement_usage (
      tenant_id TEXT NOT NULL,operation_id TEXT NOT NULL,implement_id TEXT NOT NULL,
      snapshot_json TEXT NOT NULL,PRIMARY KEY(tenant_id,operation_id,implement_id),
      FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id))''',
]


def catalog(db,tenant):
    result=[]
    for row in db.execute("SELECT record_id,payload FROM records WHERE farm_id=? AND module='implements' AND deleted=0",(tenant,)):
        raw=json.loads(row['payload'])
        if raw.get('archived') or raw.get('active') is False: continue
        result.append({'id':row['record_id'],**{k:raw.get(k) for k in ('name','type','brand','model','compatibleMachine')}})
    return result


def persist(db,user,body):
    if not body.implement_ids:return
    commercial.write_access(db,user['farmId'],'fleet')
    available={item['id']:item for item in catalog(db,user['farmId'])}
    for identity in body.implement_ids:
        item=available.get(str(identity))
        if item is None:raise HTTPException(422,'Selecione um implemento ativo e sincronizado desta organização.')
        db.execute('INSERT INTO v2_implement_usage VALUES(?,?,?,?)',(user['farmId'],str(body.id),str(identity),json.dumps(item,ensure_ascii=False)))


def read(db,tenant,operation_id):
    return [json.loads(r[0]) for r in db.execute('SELECT snapshot_json FROM v2_implement_usage WHERE tenant_id=? AND operation_id=? ORDER BY implement_id',(tenant,str(operation_id)))]
