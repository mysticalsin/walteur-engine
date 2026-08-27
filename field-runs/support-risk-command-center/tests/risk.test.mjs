import test from 'node:test';
import assert from 'node:assert/strict';
import { summarizeTickets, riskLabel, sortByRisk } from '../src/risk.mjs';

const today = new Date('2026-06-24T12:00:00Z');

const tickets = [
  { id: 'T-100', title: 'VIP login failure', owner: 'Maya', priority: 'high', status: 'blocked', ageHours: 50, slaDueAt: '2026-06-24T18:00:00Z' },
  { id: 'T-101', title: 'Invoice export delay', owner: 'Noah', priority: 'medium', status: 'open', ageHours: 30, slaDueAt: '2026-06-25T12:00:00Z' },
  { id: 'T-102', title: 'How-to question', owner: 'Ava', priority: 'low', status: 'open', ageHours: 5, slaDueAt: '2026-06-28T12:00:00Z' },
  { id: 'T-103', title: 'Enterprise outage follow-up', owner: 'Maya', priority: 'critical', status: 'open', ageHours: 3, slaDueAt: '2026-06-24T13:00:00Z' }
];

test('riskLabel ranks blocked tickets as critical action', () => {
  assert.equal(riskLabel(tickets[0], today).label, 'Blocked');
  assert.equal(riskLabel(tickets[0], today).score, 100);
});

test('riskLabel ranks SLA-near tickets above aging open tickets', () => {
  const slaNear = riskLabel(tickets[3], today);
  const aging = riskLabel(tickets[1], today);

  assert.equal(slaNear.label, 'SLA near');
  assert.ok(slaNear.score > aging.score);
});

test('sortByRisk orders the highest operational risks first', () => {
  const ordered = sortByRisk(tickets, today).map((ticket) => ticket.id);

  assert.deepEqual(ordered.slice(0, 3), ['T-100', 'T-103', 'T-101']);
});

test('summarizeTickets returns decision-ready counts and owner load', () => {
  const summary = summarizeTickets(tickets, today);

  assert.equal(summary.total, 4);
  assert.equal(summary.blocked, 1);
  assert.equal(summary.slaNear, 1);
  assert.equal(summary.aging, 1);
  assert.deepEqual(summary.ownerLoad, [
    { owner: 'Maya', count: 2, highestRisk: 100 },
    { owner: 'Noah', count: 1, highestRisk: 60 },
    { owner: 'Ava', count: 1, highestRisk: 10 }
  ]);
});
