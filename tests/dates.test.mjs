// Due date logic tests (browser ka JS, bina browser ke). Chalao: node --test tests/*.test.mjs
// Ye wahi cases hain jo tests/db_test.sql database mein check karta hai,
// taaki form ka preview aur database ki asli date ek jaisi rahe.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const el = { innerHTML: '', addEventListener() {} };
globalThis.window = globalThis;
globalThis.document = { addEventListener() {}, getElementById: () => el, querySelector: () => null };
globalThis.MutationObserver = class { observe() {} };
globalThis.setInterval = () => 0;
new Function(readFileSync(new URL('../data.js', import.meta.url), 'utf8'))();
const G = globalThis.G;

test('month end clamp jaisa Postgres: 31 Jan + 1 = 28 Feb', () => {
  assert.equal(G.addMonths('2026-01-31', 1), '2026-02-28');
  assert.equal(G.addMonths('2028-01-31', 1), '2028-02-29'); // leap year
  assert.equal(G.addMonths('2026-08-31', 6), '2027-02-28');
  assert.equal(G.addMonths('2026-03-15', 12), '2027-03-15');
});

test('jab se due tha: purani due date + plan', () => {
  const m = { due: '2026-11-10', plan: 'Monthly' };
  assert.equal(G.nextDue(m, 'Monthly', 'due'), '2026-12-10');
  assert.equal(G.nextDue(m, 'Quarterly', 'due'), '2027-02-10');
  assert.equal(G.nextDue(m, 'Half-yearly', 'due'), '2027-05-10');
  assert.equal(G.nextDue(m, 'Yearly', 'due'), '2027-11-10');
});

test('aaj se: aaj ki date + plan', () => {
  const m = { due: '2020-01-01', plan: 'Monthly' };
  assert.equal(G.nextDue(m, 'Quarterly', 'today'), G.addMonths(G.iso(G.today), 3));
});

test('status: overdue / due soon / active', () => {
  const d = n => G.iso(G.today.getTime() + n * 86400000);
  assert.equal(G.status({ due: d(-1) }), 'overdue');
  assert.equal(G.status({ due: d(0) }), 'due');
  assert.equal(G.status({ due: d(7) }), 'due');
  assert.equal(G.status({ due: d(8) }), 'active');
});

test('dusre saal ki date pe saal dikhe', () => {
  const y = G.today.getFullYear();
  assert.doesNotMatch(G.nice(`${y}-03-15`), new RegExp(String(y)));
  assert.match(G.nice(`${y + 1}-03-15`), new RegExp(String(y + 1)));
});
