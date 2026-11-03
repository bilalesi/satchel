#!/usr/bin/env bun
/// <reference types="bun" />
/**
 * One command from this folder to the site live on https://SUBDOMAIN.DOMAIN (satchel.echospace.dev):
 *
 *   1. Cloudflare: registers a workers.dev subdomain on a new account (the first deploy needs one)
 *   2. Cloudflare: creates the zone for DOMAIN
 *   3. DNS: copies every record from Vercel, and adds records for the Vercel projects that serve
 *      DOMAIN or its subdomains, so those sites keep working after the move
 *   4. Vercel: points DOMAIN's nameservers to Cloudflare (asks first)
 *   5. GitHub: stores the Cloudflare secrets, so every push to main that changes website/ deploys
 *      through .github/workflows/website.yml
 *   6. Deploy: builds and deploys now; on SUBDOMAIN.DOMAIN once the zone is active, on workers.dev before
 *
 * Every step checks what already exists, so running it again is safe. Run it again after the
 * nameservers have propagated to attach the domain.
 *
 *   bun run setup            # interactive
 *   bun run setup --yes      # no confirmation before changing nameservers
 */

const env = Bun.env;
const yes = Bun.argv.includes('--yes');
const root = new URL('..', import.meta.url).pathname;

const log = {
  step: (m: string) => console.log(`\n\x1b[1m▸ ${m}\x1b[0m`),
  info: (m: string) => console.log(`  ${m}`),
  ok: (m: string) => console.log(`  \x1b[32m✓\x1b[0m ${m}`),
  warn: (m: string) => console.log(`  \x1b[33m!\x1b[0m ${m}`),
  fail: (m: string): never => {
    console.error(`\n  \x1b[31m✗ ${m}\x1b[0m\n`);
    process.exit(1);
  },
};

/* ---------- config ---------- */

function need(name: string) {
  const v = env[name]?.trim();
  if (!v) log.fail(`${name} is missing. Copy .env.example to .env and fill it in.`);
  return v as string;
}
const CF_TOKEN = need('CLOUDFLARE_API_TOKEN');
const CF_ACCOUNT = need('CLOUDFLARE_ACCOUNT_ID');
const VERCEL_TOKEN = need('VERCEL_TOKEN');
const VERCEL_TEAM = env.VERCEL_TEAM_ID?.trim() || '';
const DOMAIN = env.DOMAIN?.trim() || 'echospace.dev';
const SITE = `${env.SUBDOMAIN?.trim() || 'satchel'}.${DOMAIN}`;
const WORKER = env.WORKER_NAME?.trim() || 'satchel-website';

/* ---------- helpers ---------- */

async function run(cmd: string[], opts: { stdin?: string; allowFail?: boolean; live?: boolean } = {}) {
  const proc = Bun.spawn(cmd, {
    cwd: root,
    stdin: opts.stdin === undefined ? 'inherit' : new Blob([opts.stdin]),
    stdout: opts.live ? 'inherit' : 'pipe',
    stderr: opts.live ? 'inherit' : 'pipe',
  });
  const [out, err, code] = opts.live
    ? ['', '', await proc.exited]
    : await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0 && !opts.allowFail) log.fail(`${cmd.join(' ')}\n${err || out}`);
  return { ok: code === 0, out: out.trim(), err: err.trim() };
}

type CfResult<T> = { success: boolean; errors: { code: number; message: string }[]; result: T };
async function cf<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`https://api.cloudflare.com/client/v4${path}`, {
    method,
    headers: { Authorization: `Bearer ${CF_TOKEN}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = (await res.json()) as CfResult<T>;
  if (!data.success) log.fail(`Cloudflare ${method} ${path}: ${data.errors.map((e) => `${e.code} ${e.message}`).join('; ')}`);
  return data.result;
}

async function vercel(method: string, path: string, body?: unknown) {
  const url = new URL(`https://api.vercel.com${path}`);
  if (VERCEL_TEAM) url.searchParams.set('teamId', VERCEL_TEAM);
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${VERCEL_TOKEN}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, data: text ? (JSON.parse(text) as any) : null };
}

function confirm(question: string) {
  if (yes) return true;
  const answer = prompt(`  ${question} [y/N]`);
  return answer?.trim().toLowerCase() === 'y';
}

/* ---------- 0. tools ---------- */

log.step('Checking tools');
for (const tool of ['git', 'gh', 'npm']) {
  if (!Bun.which(tool)) log.fail(`${tool} is not installed. Install it first (gh: https://cli.github.com).`);
}
const auth = await run(['gh', 'auth', 'status'], { allowFail: true });
if (!auth.ok) log.fail('GitHub CLI is not signed in. Run: gh auth login');
const login = (await run(['gh', 'api', 'user', '--jq', '.login'])).out;
const repo = env.GITHUB_REPO?.trim() || (await run(['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'])).out;
if (!Bun.file(`${root}node_modules/.bin/wrangler`).size) await run(['npm', 'ci'], { live: true });
log.ok(`git, gh (signed in as ${login}), wrangler; repository ${repo}`);

/* ---------- 1. Cloudflare workers.dev subdomain ---------- */

// A new account has no workers.dev subdomain, and `wrangler deploy` refuses to run without one.
log.step('Cloudflare workers.dev subdomain');
let workersSubdomain = '';
{
  const headers = { Authorization: `Bearer ${CF_TOKEN}`, 'Content-Type': 'application/json' };
  const url = `https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/workers/subdomain`;
  const current = (await (await fetch(url, { headers })).json()) as CfResult<{ subdomain: string } | null>;
  if (current.success && current.result?.subdomain) {
    workersSubdomain = current.result.subdomain;
    log.ok(`${workersSubdomain}.workers.dev`);
  } else {
    const base = (env.WORKERS_SUBDOMAIN?.trim() || login).toLowerCase().replace(/[^a-z0-9-]/g, '-');
    for (const candidate of [base, `${base}-dev`, `${base}-${CF_ACCOUNT.slice(0, 6)}`]) {
      const res = (await (await fetch(url, { method: 'PUT', headers, body: JSON.stringify({ subdomain: candidate }) })).json()) as CfResult<{ subdomain: string }>;
      if (res.success) { workersSubdomain = res.result.subdomain; break; }
      log.warn(`${candidate}.workers.dev: ${res.errors.map((e) => e.message).join('; ')}`);
    }
    if (!workersSubdomain) log.fail(`Could not register a workers.dev subdomain. Pick one at https://dash.cloudflare.com/${CF_ACCOUNT}/workers/onboarding and run the setup again.`);
    log.ok(`Registered ${workersSubdomain}.workers.dev`);
  }
}

/* ---------- 2. Cloudflare zone ---------- */

log.step(`Cloudflare zone for ${DOMAIN}`);
type Zone = { id: string; status: string; name_servers: string[] };
let [zone] = await cf<Zone[]>('GET', `/zones?name=${DOMAIN}&account.id=${CF_ACCOUNT}`);
if (!zone) {
  zone = await cf<Zone>('POST', '/zones', { name: DOMAIN, account: { id: CF_ACCOUNT }, type: 'full' });
  log.ok('Created the zone (free plan)');
} else {
  log.ok(`Zone exists, status: ${zone.status}`);
}
log.info(`Cloudflare nameservers: ${zone.name_servers.join(', ')}`);

/* ---------- 3. DNS from Vercel ---------- */

// Unlike a domain that moves whole, other sites may still live on Vercel under DOMAIN. Vercel serves
// its project domains without listing them as DNS records, so they are added here explicitly:
// otherwise those sites would go dark the moment the nameservers change.
log.step('Copying DNS from Vercel');
{
  type CfRecord = { type: string; name: string; content: string };
  const existing = await cf<CfRecord[]>('GET', `/zones/${zone.id}/dns_records?per_page=500`);
  const key = (t: string, n: string, c: string) => `${t}|${n}|${c.replace(/^"|"$/g, '').replace(/\.$/, '')}`.toLowerCase();
  const have = new Set(existing.map((r) => key(r.type, r.name, r.content)));
  const haveName = new Set(existing.filter((r) => ['A', 'AAAA', 'CNAME'].includes(r.type)).map((r) => r.name.toLowerCase()));
  let copied = 0;

  async function add(body: Record<string, unknown>, shown: string) {
    const name = String(body.name);
    const content = String(body.content ?? JSON.stringify(body.data));
    if (have.has(key(String(body.type), name, content))) return;
    // A CNAME cannot share its name with any other record; an existing address record wins.
    if (body.type === 'CNAME' && haveName.has(name.toLowerCase())) return;
    const res = await fetch(`https://api.cloudflare.com/client/v4/zones/${zone.id}/dns_records`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${CF_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ttl: 1, proxied: false, ...body }),
    });
    const data = (await res.json()) as CfResult<unknown>;
    if (!data.success) {
      // Cloudflare normalises content (quotes, trailing dots, flattening), so a record can match without
      // matching the key above: "identical record" (81058) or "name already taken" (81053) means it is there.
      const codes = data.errors.map((e) => e.code);
      if (codes.includes(81058) || codes.includes(81053)) return;
      log.fail(`Cloudflare POST dns_records ${shown}: ${data.errors.map((e) => `${e.code} ${e.message}`).join('; ')}`);
    }
    have.add(key(String(body.type), name, content));
    if (['A', 'AAAA', 'CNAME'].includes(String(body.type))) haveName.add(name.toLowerCase());
    log.ok(shown);
    copied++;
  }

  // 3a. Explicit records (mail, verification, other services).
  type VRecord = { name: string; type: string; value: string; mxPriority?: number; priority?: number };
  const vr = await vercel('GET', `/v4/domains/${DOMAIN}/records?limit=100`);
  if (vr.status !== 200) {
    log.warn(`Could not read Vercel DNS (${vr.status}: ${vr.data?.error?.message ?? 'unknown'}). Check the records in Cloudflare by hand.`);
  } else {
    for (const r of (vr.data?.records ?? []) as VRecord[]) {
      const name = r.name ? `${r.name}.${DOMAIN}` : DOMAIN;
      if (r.type === 'NS' || name === SITE) continue; // SITE is the Worker's custom domain: Cloudflare creates it
      const type = r.type === 'ALIAS' ? 'CNAME' : r.type; // Cloudflare flattens a CNAME at the apex
      if (!['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'CAA'].includes(type)) {
        log.warn(`Skipped ${r.type} ${name} (${r.value}): add it in Cloudflare by hand`);
        continue;
      }
      const body: Record<string, unknown> = { type, name };
      if (type === 'CAA') {
        const [flags, tag, ...rest] = r.value.split(' ');
        body.data = { flags: Number(flags), tag, value: rest.join(' ').replace(/^"|"$/g, '') };
      } else {
        body.content = r.value;
      }
      if (type === 'MX') body.priority = r.mxPriority ?? r.priority ?? 10;
      await add(body, `${type} ${name} → ${r.value}`);
    }
  }

  // 3b. Vercel projects that serve DOMAIN or a subdomain of it.
  const hosts = new Set<string>();
  let next: number | null = 0;
  while (next !== null) {
    const page = await vercel('GET', `/v10/projects?limit=100${next ? `&until=${next}` : ''}`);
    if (page.status !== 200) { log.warn(`Could not list Vercel projects (${page.status}). Check the sites under ${DOMAIN} by hand.`); break; }
    for (const p of page.data.projects ?? []) {
      const d = await vercel('GET', `/v9/projects/${p.id}/domains?limit=100`);
      for (const { name } of d.data?.domains ?? []) {
        if ((name === DOMAIN || name.endsWith(`.${DOMAIN}`)) && name !== SITE) hosts.add(name);
      }
    }
    next = page.data.pagination?.next ?? null;
  }
  for (const host of hosts) {
    if (host === DOMAIN) await add({ type: 'A', name: host, content: '76.76.21.21' }, `A ${host} → Vercel (keeps that site on Vercel)`);
    else await add({ type: 'CNAME', name: host, content: 'cname.vercel-dns.com' }, `CNAME ${host} → Vercel (keeps that site on Vercel)`);
  }

  log.ok(copied ? `Added ${copied} record(s)` : 'Cloudflare already has every record');
}

/* ---------- 4. nameservers ---------- */

if (zone.status !== 'active') {
  log.step('Pointing the domain to Cloudflare');
  log.info(`This moves DNS for ${DOMAIN} from Vercel to Cloudflare. The records above keep the other sites working.`);
  if (confirm(`Change the nameservers of ${DOMAIN} to ${zone.name_servers.join(', ')}?`)) {
    const ns = await vercel('PATCH', `/v1/registrar/domains/${DOMAIN}/nameservers`, { nameservers: zone.name_servers });
    if (ns.status === 204 || ns.status === 200) {
      log.ok('Nameservers updated at Vercel');
    } else if (ns.data?.code === 'domain_not_registered') {
      log.warn(`${DOMAIN} is not registered through Vercel. Set these nameservers at your registrar:`);
      zone.name_servers.forEach((n) => log.info(`  ${n}`));
    } else {
      log.warn(`Vercel answered ${ns.status}: ${ns.data?.message ?? JSON.stringify(ns.data)}. Set the nameservers by hand.`);
    }
    await fetch(`https://api.cloudflare.com/client/v4/zones/${zone.id}/activation_check`, {
      method: 'PUT',
      headers: { Authorization: `Bearer ${CF_TOKEN}` },
    });
  } else {
    log.warn('Skipped. Run the setup again when you are ready.');
  }
  zone = await cf<Zone>('GET', `/zones/${zone.id}`);
}

/* ---------- 5. GitHub secrets ---------- */

log.step(`GitHub secrets for ${repo}`);
await run(['gh', 'secret', 'set', 'CLOUDFLARE_API_TOKEN', '--repo', repo], { stdin: CF_TOKEN });
await run(['gh', 'secret', 'set', 'CLOUDFLARE_ACCOUNT_ID', '--repo', repo], { stdin: CF_ACCOUNT });
log.ok('Saved CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID: pushes to main that change website/ deploy');

/* ---------- 6. build and deploy ---------- */

log.step('Building and deploying');
await run(['npm', 'run', 'build'], { live: true });
if (zone.status === 'active') {
  await run(['npx', 'wrangler', 'deploy'], { live: true });
  log.ok(`Deployed on https://${SITE}`);
} else {
  // The custom domain needs an active zone. Until then, deploy the same files to workers.dev only,
  // with a copy of the config that has no route (kept in .wrangler/, which git ignores).
  const config = (await Bun.file(`${root}wrangler.jsonc`).text())
    .replace(/^\s*"routes":.*\n/m, '')
    .replace('"./dist"', '"../dist"')
    .replace('"./node_modules/', '"../node_modules/');
  await Bun.write(`${root}.wrangler/preview.jsonc`, config);
  await run(['npx', 'wrangler', 'deploy', '--config', '.wrangler/preview.jsonc'], { live: true });
  log.warn(`Zone status is "${zone.status}". Nameserver changes take from minutes to a few hours.`);
  log.info(`Meanwhile the site is live on https://${WORKER}.${workersSubdomain}.workers.dev`);
  log.info(`Run \`bun run setup\` again later: it deploys on ${SITE} as soon as the zone is active.`);
}

/* ---------- done ---------- */

console.log(`
\x1b[1mDone.\x1b[0m
  Site         https://${SITE} (zone ${zone.status})
  Worker       https://dash.cloudflare.com/${CF_ACCOUNT}/workers/services/view/${WORKER}/production
  Deploys      https://github.com/${repo}/actions/workflows/website.yml

From now on: edit website/, commit, push to main. The site updates in about a minute.
`);
