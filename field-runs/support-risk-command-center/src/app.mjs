import { summarizeTickets } from './risk.mjs';
import { renderOwnerLoad, renderRiskRows, renderSummaryCards } from './view.mjs';

const NOW = new Date('2026-06-24T12:00:00Z');

async function loadTickets() {
  const response = await fetch('./data/tickets.json');
  if (!response.ok) throw new Error(`Could not load tickets: ${response.status}`);
  return response.json();
}

function showError(error) {
  document.querySelector('#app').innerHTML = `
    <section class="state-card error-state">
      <h2>Could not load support risk data</h2>
      <p>${error.message}</p>
      <p>Recovery: refresh the page or verify that <code>data/tickets.json</code> is present.</p>
    </section>
  `;
}

function render(tickets) {
  const summary = summarizeTickets(tickets, NOW);
  document.querySelector('#summary').innerHTML = renderSummaryCards(summary);
  document.querySelector('#risk-rows').innerHTML = renderRiskRows(tickets, NOW);
  document.querySelector('#owner-load').innerHTML = renderOwnerLoad(summary.ownerLoad);
  document.querySelector('#loaded-at').textContent = `Seeded snapshot: ${NOW.toISOString()}`;
}

loadTickets().then(render).catch(showError);
