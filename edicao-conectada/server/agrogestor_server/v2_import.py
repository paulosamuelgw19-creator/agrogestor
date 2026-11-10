"""Reviewable, idempotent import of legacy catalogs. Never rewrites legacy data.

python -m agrogestor_server.v2_import plan --source-db ... --output plan.json
python -m agrogestor_server.v2_import apply --plan plan.json --server https://...
An authenticated administrator token is requested privately on apply.
"""
import argparse
import getpass
import hashlib
import json
from pathlib import Path
import sqlite3
import urllib.request
from urllib.parse import urlparse
from uuid import NAMESPACE_URL, uuid5
from .v2_models import ClientBody, PropertyBody, PlotBody, MachineBody, InputBody

MODELS = {'/clients': ClientBody, '/properties': PropertyBody, '/plots': PlotBody,
          '/machines': MachineBody, '/inputs': InputBody}


def build_plan(rows, tenant, machine_properties=None):
    requests, warnings, mapping, candidates = [], [], {}, []
    seen = {}
    assignments = machine_properties or {}
    def key(kind, source):
        result = str(uuid5(NAMESPACE_URL, f'agrogestor-v2/{tenant}/{kind}/{source}'))
        mapping[f'{kind}/{source}'] = result
        return result
    def append(path, body, origin):
        try:
            validated = MODELS[path].model_validate(body)
            value = validated.model_dump(mode='json')
            identity = (path, value['id'])
            if identity in seen:
                warnings.append(f'{origin}: ID legado repetido; revisar antes de importar.')
                return False
            seen[identity] = value
            requests.append({'path': path, 'body': value, 'origin': origin})
            return True
        except ValueError:
            warnings.append(f'{origin}: campos incompletos/inválidos; cadastro não incluído.')
            return False
    for row in rows:
        if row['module'] != 'clients':
            continue
        try:
            client = json.loads(row['payload'])
            source = row['record_id']
            if not append('/clients', {'id': key('client', source), 'name': client.get('name')}, 'client/' + source):
                continue
            for prop in client.get('properties', []):
                prop_source = source + '/' + str(prop.get('id', ''))
                if not prop.get('id'):
                    warnings.append(f'{prop_source}: imóvel sem ID; exige mapeamento manual.')
                    continue
                # Defaults from old constructors do not prove measured areas.
                if not append('/properties', {'id': key('property', prop_source), 'name': prop.get('name'),
                          'client_id': mapping['client/' + source], 'area_ha': None,
                          'location': prop.get('location', ''), 'notes': prop.get('notes', '')}, 'property/' + prop_source):
                    continue
                warnings.append(f'property/{prop_source}: conferir área; valor antigo não promovido a medição.')
                for plot in prop.get('fields', []):
                    plot_source = prop_source + '/' + str(plot.get('id', ''))
                    if not plot.get('id'):
                        warnings.append(f'{plot_source}: talhão sem ID; exige mapeamento manual.')
                        continue
                    append('/plots', {'id': key('plot', plot_source), 'name': plot.get('name'),
                          'property_id': mapping['property/' + prop_source], 'area_ha': None,
                          'notes': plot.get('notes', '')}, 'plot/' + plot_source)
                warnings.append(f'property/{prop_source}: conferir talhões, culturas, áreas e safras. Nenhuma safra foi inventada.')
        except (ValueError, TypeError, AttributeError):
            warnings.append(f'client/{row["record_id"]}: JSON legado inválido; exige revisão.')
    for row in rows:
        source = row['record_id']
        try:
            data = json.loads(row['payload'])
            if row['module'] == 'machines':
                candidates.append({'legacy_id': source, 'name': data.get('name'), 'hour_meter': data.get('hourMeter')})
                properties = assignments.get(source, [])
                if not properties:
                    warnings.append(f'machine/{source}: selecione propriedades e confira o horímetro antes de importar.')
                    continue
                append('/machines', {'id': key('machine', source), 'name': data.get('name'),
                       'hour_meter': data.get('hourMeter'), 'hourly_cost_cents': None, 'property_ids': properties}, 'machine/' + source)
            elif row['module'] == 'products':
                unit = data.get('unit')
                if unit not in {'L', 'kg', 'un'}:
                    warnings.append(f'input/{source}: unidade não normalizada; exige confirmação, sem conversão automática.')
                    continue
                append('/inputs', {'id': key('input', source), 'name': data.get('name'), 'unit': unit,
                                  'category': data.get('category', ''),
                                  'product_type': data.get('productType', '')}, 'input/' + source)
                warnings.append(f'input/{source}: conferir inventário inicial por propriedade. Quantidade/valor antigos não importados como saldo.')
        except (ValueError, TypeError, AttributeError):
            warnings.append(f'{row["module"]}/{source}: JSON legado inválido; exige revisão.')
    return {'format': 1, 'organization': tenant, 'requests': requests, 'mapping': mapping,
            'machine_candidates': candidates, 'warnings': warnings,
            'not_imported': ['Histórico v1 permanece intacto', 'Safras/culturas não confirmadas',
                             'Áreas não conferidas', 'Saldos e preços não conferidos', 'Permissões de propriedade']}


def read_plan(source, assignments=None):
    path = Path(source).resolve()
    db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    try:
        db.execute('BEGIN')
        tenant = db.execute('SELECT farm_id FROM farm WHERE singleton=1').fetchone()[0]
        rows = [dict(r) for r in db.execute("SELECT module,record_id,payload FROM records WHERE farm_id=? AND deleted=0 AND module IN ('clients','machines','products') ORDER BY module,record_id", (tenant,))]
        result = build_plan(rows, tenant, assignments)
        result['source_records_sha256'] = hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()
        return result
    finally:
        db.close()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def apply_plan(plan, server, token):
    uri = urlparse(server)
    if uri.username or uri.password or uri.query or uri.fragment or uri.path not in ('', '/'):
        raise ValueError('Use somente o endereço base do servidor, sem credenciais nem parâmetros.')
    if uri.scheme != 'https' and not (uri.scheme == 'http' and uri.hostname in {'127.0.0.1', 'localhost'}):
        raise ValueError('A importação exige HTTPS ou desenvolvimento local.')
    opener = urllib.request.build_opener(NoRedirect())
    def send(path, body=None):
        request = urllib.request.Request(server.rstrip('/') + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        with opener.open(request, timeout=30) as response:
            return json.load(response)
    session = send('/api/v2/workspace')
    if session.get('organization_id') != plan['organization'] or not session.get('administrator'):
        raise ValueError('A conta deve ser administradora da organização original do plano.')
    count = 0
    for item in plan['requests']:
        model = MODELS[item['path']].model_validate(item['body'])
        send('/api/v2' + item['path'], model.model_dump(mode='json'))
        count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    generate = sub.add_parser('plan')
    generate.add_argument('--source-db', required=True)
    generate.add_argument('--output', required=True)
    generate.add_argument('--machine-properties')
    apply = sub.add_parser('apply')
    apply.add_argument('--plan', required=True)
    apply.add_argument('--server', required=True)
    args = parser.parse_args()
    if args.command == 'plan':
        assignments = json.loads(Path(args.machine_properties).read_text(encoding='utf-8')) if args.machine_properties else None
        plan = read_plan(args.source_db, assignments)
        Path(args.output).write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f'Plano criado: {len(plan["requests"])} cadastros, {len(plan["warnings"])} avisos. Nenhum dado foi alterado.')
    else:
        plan = json.loads(Path(args.plan).read_text(encoding='utf-8'))
        token = getpass.getpass('Token temporário do administrador (não será gravado): ')
        print(f'Cadastros confirmados: {apply_plan(plan, args.server, token)}. Confira os avisos e os vínculos antes de usar.')


if __name__ == '__main__':
    main()
