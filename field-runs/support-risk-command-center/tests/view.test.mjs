import test from 'node:test';
import assert from 'node:assert/strict';
import { renderSummaryCards, renderRiskRows } from '../src/view.mjs';

const summary = { total: 4, blocked: 1, slaNear: 1, aging: 1, ownerLoad: [] };
const tickets = [
  { id: 'T-100', title: 'VIP login failure', owner: 'Maya', priority: 'high', status: 'blocked', ageHours: 50, slaDueAt: '2026-06-24T18:00:00Z' }
];
const today = new Date('2026-06-24T12:00:00Z');

test('renderSummaryCards exposes the decision counts', () => {
  const html = renderSummaryCards(summary);

  assert.match(html, /Total tickets/);
  assert.match(html, /Blocked/);
  assert.match(html, /SLA near/);
  assert.match(html, /Aging/);
});

test('renderRiskRows includes the risk label and owner for each ticket', () => {
  const html = renderRiskRows(tickets, today);

  assert.match(html, /T-100/);
  assert.match(html, /VIP login failure/);
  assert.match(html, /Maya/);
  assert.match(html, /Blocked/);
});
