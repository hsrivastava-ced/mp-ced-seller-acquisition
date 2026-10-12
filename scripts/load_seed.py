#!/usr/bin/env python3
"""Provision a fresh Supabase project for the Acquisition Hub and load the seed.

Reads ./.env (never printed):
  SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, SUPABASE_ACCESS_TOKEN,
  GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET (optional until Google sign-in is configured),
  APP_URL (optional; defaults to the workers.dev URL)

Steps (each idempotent):
  schema   run supabase/schema.sql via the Management API
  auth     enable Google provider, disable email/password sign-up, set site + redirect URLs
  data     upsert programs, sellers, qualified_sellers, payments, campaigns, ab_brands, SHEIN seed
  verify   counts + RLS smoke test (anon must see 0 rows)

Usage: python3 -I scripts/load_seed.py [schema] [auth] [data] [verify]   (default: all)
"""
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_APP_URL = 'https://mp-ced-seller-acquisition.hsrivastava.workers.dev'


def load_env():
    env = {}
    for line in (ROOT / '.env').read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    missing = [k for k in ('SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_SECRET_KEY', 'SUPABASE_ACCESS_TOKEN')
               if not env.get(k)]
    if missing:
        sys.exit('Missing in .env: ' + ', '.join(missing))
    env['SUPABASE_URL'] = env['SUPABASE_URL'].rstrip('/')
    env['REF'] = re.match(r'https://([a-z0-9]+)\.supabase\.co', env['SUPABASE_URL']).group(1)
    return env


def http(method, url, headers, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={'Content-Type': 'application/json', 'User-Agent': 'mp-hub-loader', **headers})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            txt = r.read().decode()
            return r.status, (json.loads(txt) if txt else None), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:800], {}


def mgmt(env, method, path, body=None):
    st, res, _ = http(method, 'https://api.supabase.com/v1/projects/' + env['REF'] + path,
                      {'Authorization': 'Bearer ' + env['SUPABASE_ACCESS_TOKEN']}, body)
    if st >= 300:
        sys.exit(f'Management API {method} {path} -> {st}: {res}')
    return res


def rest(env, method, path, body=None, key='secret', extra=None):
    k = env['SUPABASE_SECRET_KEY'] if key == 'secret' else env['SUPABASE_PUBLISHABLE_KEY']
    h = {'apikey': k, **(extra or {})}
    if k.startswith('eyJ'):  # legacy JWT keys also go in Authorization
        h['Authorization'] = 'Bearer ' + k
    return http(method, env['SUPABASE_URL'] + '/rest/v1/' + path, h, body)


def step_schema(env):
    sql = (ROOT / 'supabase' / 'schema.sql').read_text()
    mgmt(env, 'POST', '/database/query', {'query': sql})
    print('schema: applied supabase/schema.sql')


def step_auth(env):
    app = env.get('APP_URL', DEFAULT_APP_URL).rstrip('/')
    cfg = {'site_url': app,
           'uri_allow_list': ','.join([app, app + '/**', 'http://localhost:8788/**']),
           'external_email_enabled': False,      # Google only — no unverified email/password accounts
           'disable_signup': False}
    if env.get('GOOGLE_CLIENT_ID') and env.get('GOOGLE_CLIENT_SECRET'):
        cfg.update({'external_google_enabled': True,
                    'external_google_client_id': env['GOOGLE_CLIENT_ID'],
                    'external_google_secret': env['GOOGLE_CLIENT_SECRET']})
    else:
        print('auth: GOOGLE_CLIENT_ID/SECRET not in .env yet — Google provider left unchanged')
    mgmt(env, 'PATCH', '/config/auth', cfg)
    print(f'auth: site_url={app}, email sign-up disabled'
          + (', Google enabled' if 'external_google_enabled' in cfg else ''))


def upsert(env, table, rows, conflict='id', batch=500):
    for i in range(0, len(rows), batch):
        st, res, _ = rest(env, 'POST', f'{table}?on_conflict={conflict}', rows[i:i + batch],
                          extra={'Prefer': 'resolution=merge-duplicates,return=minimal'})
        if st >= 300:
            sys.exit(f'upsert {table} [{i}] -> {st}: {res}')
    print(f'data: {table} <- {len(rows)}')


def step_data(env):
    seed = json.loads((ROOT / 'data' / 'seed' / 'seed.json').read_text())
    shein = seed.pop('_shein')
    programs = seed['programs'] + [{k: v for k, v in shein['program'].items() if k != 'created_at'}]
    upsert(env, 'programs', programs)
    sellers = seed['sellers'] + shein['sellers']
    cols = ['id', 'program_id', 'email', 'company', 'status', 'sources', 'associate', 'store_id', 'tags',
            'phone', 'remarks', 'website', 'qualified', 'campaign', 'meta']
    upsert(env, 'sellers', [{c: s.get(c, [] if c in ('sources', 'tags') else {} if c == 'meta' else None)
                             for c in cols} for s in sellers])
    upsert(env, 'qualified_sellers', seed['qualified_sellers'])
    upsert(env, 'payments', seed['payments'])
    upsert(env, 'campaigns', seed['campaigns'])
    brands = json.loads((ROOT / 'data' / 'shein-ab-brands' / 'brands.json').read_text())
    seen, rows = set(), []
    for b in brands:
        if b['brand_code'] in seen:
            continue
        seen.add(b['brand_code'])
        rows.append({'brand_code': b['brand_code'], 'brand_name': b['brand_name'],
                     'brand_norm': re.sub(r'[^a-z0-9]', '', str(b['brand_name']).lower()),
                     'brand_level': b['brand_level'], 'tier': b['tier'], 'last_brand_level': b.get('last_brand_level'),
                     'level_update_date': b.get('level_update_date'), 'list_version': 'v4.29'})
    upsert(env, 'ab_brands', rows, conflict='brand_code', batch=1000)


def step_verify(env):
    ok = True
    for t in ('programs', 'sellers', 'qualified_sellers', 'payments', 'campaigns', 'ab_brands', 'team_permissions'):
        st, res, h = rest(env, 'GET', f'{t}?select=*', extra={'Prefer': 'count=exact', 'Range': '0-0'})
        total = (h.get('Content-Range') or h.get('content-range') or '*/?').split('/')[-1]
        st2, res2, h2 = rest(env, 'GET', f'{t}?select=*', key='anon', extra={'Prefer': 'count=exact', 'Range': '0-0'})
        anon = (h2.get('Content-Range') or h2.get('content-range') or '').split('/')[-1] if st2 < 300 else f'HTTP {st2}'
        leak = anon not in ('0', '*', '') and not str(anon).startswith('HTTP')
        ok &= not leak
        print(f'verify: {t:18} rows={total:>5}   anon sees={anon}{"   <-- RLS LEAK" if leak else ""}')
    q = mgmt(env, 'POST', '/database/query', {'query':
             "select program_id, count(*) filter (where qualified) conv, count(*) n from sellers group by 1 order by 1"})
    for r in q:
        print(f"verify: {r['program_id']:20} sellers={r['n']:>5} converted={r['conv']}")
    rls = mgmt(env, 'POST', '/database/query', {'query':
               "select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace "
               "where n.nspname='public' and c.relkind='r' and not c.relrowsecurity"})
    if rls:
        ok = False
        print('verify: RLS DISABLED on', [r['relname'] for r in rls])
    print('verify: OK' if ok else 'verify: FAILED')
    return ok


def main():
    env = load_env()
    steps = sys.argv[1:] or ['schema', 'auth', 'data', 'verify']
    for s in steps:
        {'schema': step_schema, 'auth': step_auth, 'data': step_data, 'verify': step_verify}[s](env)


if __name__ == '__main__':
    main()
