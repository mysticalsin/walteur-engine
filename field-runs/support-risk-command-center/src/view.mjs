import { riskLabel, sortByRisk } from './risk.mjs';

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

export function renderSummaryCards(summary) {
  const cards = [
    ['Total tickets', summary.total],
    ['Blocked', summary.blocked],
    ['SLA near', summary.slaNear],
    ['Aging', summary.aging]
  ];

  return cards.map(([label, value]) => `
    <article class="metric-card">
      <span>${escapeHtml(label)}</span>
      <strong>${escapeHtml(value)}</strong>
    </article>
  `).join('');
}

export function renderRiskRows(tickets, now = new Date()) {
  return sortByRisk(tickets, now).map((ticket) => {
    const risk = riskLabel(ticket, now);
    return `
      <tr>
        <td><strong>${escapeHtml(ticket.id)}</strong></td>
        <td>${escapeHtml(ticket.title)}</td>
        <td>${escapeHtml(ticket.owner)}</td>
        <td>${escapeHtml(ticket.priority)}</td>
        <td>${escapeHtml(ticket.ageHours)}h</td>
        <td><span class="risk-badge risk-${escapeHtml(risk.label.toLowerCase().replaceAll(' ', '-'))}">${escapeHtml(risk.label)}</span></td>
      </tr>
    `;
  }).join('');
}

export function renderOwnerLoad(ownerLoad) {
  return ownerLoad.map((owner) => `
    <li>
      <strong>${escapeHtml(owner.owner)}</strong>
      <span>${escapeHtml(owner.count)} open · top risk ${escapeHtml(owner.highestRisk)}</span>
    </li>
  `).join('');
}
