#!/usr/bin/env node
// End-to-end latency benchmark through the public entry point (nginx), for comparing database backends.
//   node bench.mjs [baseUrl]        default http://localhost:8087 (requires sign-up enabled)
// Creates a throwaway account + workspace; credentials go to env/secrets.bench-users.env (git-ignored).
import { appendFileSync } from 'node:fs'
import { randomBytes, randomUUID } from 'node:crypto'
import assert from 'node:assert/strict'

const base = (process.argv[2] ?? 'http://localhost:8087').replace(/\/$/, '')
const accounts = `${base}/_accounts`

async function rpc (method, params, token) {
  const res = await fetch(accounts, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ method, params })
  })
  const body = await res.json()
  if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error)}`)
  return body.result
}

async function api (path, token, body) {
  const res = await fetch(`${base}/_transactor/api/v1/${path}`, {
    method: body ? 'POST' : 'GET',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined
  })
  assert.ok(res.ok, `${path}: HTTP ${res.status} ${await res.clone().text()}`)
  return res.json()
}

const time = async (fn) => { const t = performance.now(); const r = await fn(); return [performance.now() - t, r] }
const stats = (xs) => {
  const s = [...xs].sort((a, b) => a - b)
  return { n: s.length, p50: s[Math.floor(s.length / 2)], p90: s[Math.floor(s.length * 0.9)], max: s.at(-1) }
}
const fmt = (o) => Object.entries(o).map(([k, v]) => `${k}=${typeof v === 'number' && k !== 'n' ? v.toFixed(0) + 'ms' : v}`).join(' ')

const email = `bench+${Date.now()}@tin.test`
const password = randomBytes(18).toString('base64url')
appendFileSync(new URL('./env/secrets.bench-users.env', import.meta.url), `${email} ${password}\n`, { mode: 0o600 })

const [tSignUp, login] = await time(() => rpc('signUp', { email, password, firstName: 'Bench', lastName: 'User' }))
console.log(`signUp            ${tSignUp.toFixed(0)}ms`)

const [tCreate, ws] = await time(async () => {
  const info = await rpc('createWorkspace', { workspaceName: `Bench ${Date.now()}` }, login.token)
  const deadline = Date.now() + 180_000
  for (;;) {
    const st = await rpc('getWorkspaceInfo', { updateLastVisit: false }, info.token)
    const mode = st.status?.mode ?? st.mode
    if (mode === 'active') return info
    if (mode?.includes('failed') || Date.now() > deadline) throw new Error(`workspace not active: ${JSON.stringify(st).slice(0, 400)}`)
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
})
console.log(`createWorkspace   ${tCreate.toFixed(0)}ms (until active)`)

const wsId = ws.workspace
const token = ws.token
const [tFirst] = await time(() => api(`find-all/${wsId}?class=tracker:class:Project`, token))
console.log(`first query       ${tFirst.toFixed(0)}ms (opens workspace in transactor)`)

const reads = []
for (let i = 0; i < 30; i++) reads.push((await time(() => api(`find-all/${wsId}?class=tracker:class:Project`, token)))[0])
console.log(`read projects     ${fmt(stats(reads))}`)

const issueReads = []
for (let i = 0; i < 30; i++) issueReads.push((await time(() => api(`find-all/${wsId}?class=core:class:Space&limit=50`, token)))[0])
console.log(`read spaces       ${fmt(stats(issueReads))}`)

const projects = await api(`find-all/${wsId}?class=tracker:class:Project`, token)
const project = (projects.value ?? projects)[0]
assert.ok(project?._id, 'default project missing')
const me = await api(`account/${wsId}`, token)
const socialId = me.primarySocialId ?? me.socialIds?.[0]
assert.ok(socialId, 'no social id on account')

const writes = []
for (let i = 0; i < 20; i++) {
  const tx = {
    _id: randomUUID().replace(/-/g, '').slice(0, 24),
    _class: 'core:class:TxUpdateDoc',
    space: 'core:space:Tx',
    objectId: project._id,
    objectClass: project._class,
    objectSpace: project.space,
    modifiedOn: Date.now(),
    modifiedBy: socialId,
    operations: { description: `bench ${i}` }
  }
  writes.push((await time(() => api(`tx/${wsId}`, token, tx)))[0])
}
console.log(`write (update)    ${fmt(stats(writes))}`)
const after = await api(`find-all/${wsId}?class=tracker:class:Project`, token)
assert.equal((after.value ?? after)[0].description, 'bench 19', 'last write not visible')
console.log('verified: writes persisted and readable')
