#!/usr/bin/env python3
"""End-to-end check of the deployed hub with throwaway accounts.

1. Temporarily enables email/password auth, creates two users via the admin API:
     e2e-viewer-<rand>@threecolts.com   (no team_permissions row -> viewer)
     e2e-outsider-<rand>@example.com    (not staff -> must see nothing)
2. Gets real access tokens (password grant) and checks RLS over REST:
     viewer reads every program, cannot insert/update; outsider reads 0 rows.
3. Loads the live site in headless Chromium as the viewer (session injected into
   localStorage), walks Overview/Sellers/Revenue per program, screenshots each.
4. Always cleans up: deletes both users, re-disables email/password auth.

Usage: python3 -I scripts/e2e_check.py <app_url>
"""
import json
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import load_seed as L  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / 'data' / 'e2e'


def auth(env, method, path, body=None, token=None):
    h = {'apikey': env['SUPABASE_SECRET_KEY'] if token is None else env['SUPABASE_PUBLISHABLE_KEY']}
    if token:
        h['Authorization'] = 'Bearer ' + token
    elif env['SUPABASE_SECRET_KEY'].startswith('eyJ'):
        h['Authorization'] = 'Bearer ' + env['SUPABASE_SECRET_KEY']
    return L.http(method, env['SUPABASE_URL'] + '/auth/v1/' + path, h, body)


def as_user(env, token, method, path, body=None, extra=None):
    h = {'apikey': env['SUPABASE_PUBLISHABLE_KEY'], 'Authorization': 'Bearer ' + token, **(extra or {})}
    return L.http(method, env['SUPABASE_URL'] + '/rest/v1/' + path, h, body)


def main():
    app = sys.argv[1].rstrip('/')
    env = L.load_env()
    tag = secrets.token_hex(3)
    pw = secrets.token_urlsafe(18)
    users = {'viewer': f'e2e-viewer-{tag}@threecolts.com', 'outsider': f'e2e-outsider-{tag}@example.com'}
    ids, tokens, sessions, fails = {}, {}, {}, []

    def check(cond, msg):
        print(('PASS ' if cond else 'FAIL ') + msg)
        if not cond:
            fails.append(msg)

    L.mgmt(env, 'PATCH', '/config/auth', {'external_email_enabled': True, 'mailer_autoconfirm': False})
    try:
        for role, email in users.items():
            st, res, _ = auth(env, 'POST', 'admin/users', {'email': email, 'password': pw, 'email_confirm': True})
            assert st < 300, (st, res)
            ids[role] = res['id']
            for _ in range(20):  # auth config changes take a few seconds to propagate
                st, res, _ = L.http('POST', env['SUPABASE_URL'] + '/auth/v1/token?grant_type=password',
                                    {'apikey': env['SUPABASE_PUBLISHABLE_KEY']}, {'email': email, 'password': pw})
                if st < 300 or 'email_provider_disabled' not in str(res):
                    break
                time.sleep(5)
            assert st < 300, (st, res)
            tokens[role], sessions[role] = res['access_token'], res

        # --- RLS over REST
        progs = as_user(env, tokens['viewer'], 'GET', 'programs?select=id,name')[1]
        check(isinstance(progs, list) and {p['id'] for p in progs} >= {'temu-uk', 'temu-us', 'shein-us-ab-brands'},
              f"viewer sees all programs: {[p['id'] for p in progs] if isinstance(progs, list) else progs}")
        st, _, h = as_user(env, tokens['viewer'], 'GET', 'sellers?select=id', extra={'Prefer': 'count=exact', 'Range': '0-0'})
        n = int((h.get('Content-Range') or '*/0').split('/')[-1])
        check(n > 1000, f'viewer sees sellers ({n})')
        st, _, h = as_user(env, tokens['viewer'], 'GET', 'ab_brands?select=brand_code', extra={'Prefer': 'count=exact', 'Range': '0-0'})
        check(int((h.get('Content-Range') or '*/0').split('/')[-1]) > 3000, 'viewer (staff) can use the A/B brand list')
        st, res, _ = as_user(env, tokens['viewer'], 'POST', 'sellers',
                             {'program_id': 'temu-uk', 'email': 'should-not-insert@example.com'})
        check(st >= 400, f'viewer cannot insert sellers (HTTP {st})')
        st, res, _ = as_user(env, tokens['viewer'], 'PATCH', 'sellers?program_id=eq.temu-us', {'remarks': 'x'},
                             extra={'Prefer': 'return=representation'})
        check(st >= 400 or res == [], f'viewer cannot update sellers (HTTP {st}, rows={0 if res == [] else res})')
        st, res, _ = as_user(env, tokens['viewer'], 'POST', 'team_permissions', {'email': users['viewer'], 'role': 'super_admin'})
        check(st >= 400, f'viewer cannot grant themselves super_admin (HTTP {st})')
        for t in ('programs', 'sellers', 'ab_brands', 'payments', 'team_permissions'):
            st, res, _ = as_user(env, tokens['outsider'], 'GET', f'{t}?select=*&limit=5')
            check(st >= 400 or res == [], f'outsider (non-threecolts) sees nothing in {t}')

        # --- UI as viewer
        from playwright.sync_api import sync_playwright
        SHOTS.mkdir(parents=True, exist_ok=True)
        storage_key = f"sb-{env['REF']}-auth-token"
        sess = sessions['viewer']
        sess.setdefault('expires_at', int(time.time()) + int(sess.get('expires_in', 3600)))
        with sync_playwright() as pw_:
            b = pw_.chromium.launch()
            pg = b.new_page(viewport={'width': 1400, 'height': 1000})
            errors = []
            pg.on('pageerror', lambda e: errors.append(str(e)))
            pg.goto(app)
            pg.evaluate('([k, v]) => localStorage.setItem(k, v)', [storage_key, json.dumps(sess)])
            pg.goto(app)
            pg.wait_for_selector('#app', state='visible', timeout=30000)
            check(pg.inner_text('#db-label') == 'Database connected', 'UI: database connected')
            check('Viewer' not in pg.inner_text('#user-email-disp') and users['viewer'] in pg.inner_text('#user-email-disp'),
                  'UI: signed in as viewer')
            check(not pg.is_visible('#btn-add-seller'), 'UI: viewer has no "Add seller" button')
            for pid in ('temu-uk', 'temu-us', 'shein-us-ab-brands'):
                pg.click(f'[data-act="switch-prog"][data-id="{pid}"]')
                pg.click('.ni[data-view="overview"]')
                pg.wait_for_timeout(400)
                metrics = pg.inner_text('#ov-metrics')
                pg.screenshot(path=str(SHOTS / f'{pid}-overview.png'), full_page=True)
                print(f'  {pid} overview: ' + ' | '.join(x.strip() for x in metrics.split('\n') if x.strip())[:300])
                pg.click('.ni[data-view="sellers"]')
                pg.wait_for_timeout(300)
                print(f"  {pid} sellers: {pg.inner_text('#sellers-count')}")
                pg.screenshot(path=str(SHOTS / f'{pid}-sellers.png'))
                pg.click('.ni[data-view="revenue"]')
                pg.wait_for_timeout(300)
                print(f"  {pid} revenue: {pg.inner_text('#rev-title')}")
            pg.click('[data-act="switch-prog"][data-id="shein-us-ab-brands"]')
            pg.click('.ni[data-view="overview"]')
            pg.fill('#sh-bc-in', 'Forever21\nOziva\nCalvin Klein')
            pg.click('[data-act="shein-check"]')
            pg.wait_for_selector('#sh-bc-out table', timeout=20000)
            out = pg.inner_text('#sh-bc-out')
            check('Not on list' in out and 'Tier' in out, 'UI: SHEIN brand checker works: ' + out.split('\n')[0])
            check(not errors, f'UI: no JS errors {errors[:3]}')
            b.close()
    finally:
        for role, uid in ids.items():
            auth(env, 'DELETE', f'admin/users/{uid}')
        L.mgmt(env, 'PATCH', '/config/auth', {'external_email_enabled': False})
        print('cleanup: test users deleted, email/password auth disabled again')
    print('E2E OK' if not fails else f'E2E FAILED ({len(fails)})')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
