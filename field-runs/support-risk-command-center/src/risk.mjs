const SLA_NEAR_HOURS = 8;
const AGING_HOURS = 24;

function hoursUntil(isoTimestamp, now) {
  return (new Date(isoTimestamp).getTime() - now.getTime()) / 36e5;
}

export function riskLabel(ticket, now = new Date()) {
  if (ticket.status === 'blocked') {
    return { label: 'Blocked', score: 100 };
  }

  const hoursToSla = hoursUntil(ticket.slaDueAt, now);
  if (hoursToSla <= SLA_NEAR_HOURS) {
    return { label: 'SLA near', score: ticket.priority === 'critical' ? 95 : 85 };
  }

  if (ticket.ageHours >= AGING_HOURS) {
    return { label: 'Aging', score: 60 };
  }

  return { label: 'Normal', score: ticket.priority === 'high' ? 35 : 10 };
}

export function sortByRisk(tickets, now = new Date()) {
  return [...tickets].sort((left, right) => {
    const leftRisk = riskLabel(left, now).score;
    const rightRisk = riskLabel(right, now).score;
    if (rightRisk !== leftRisk) return rightRisk - leftRisk;
    return right.ageHours - left.ageHours;
  });
}

export function summarizeTickets(tickets, now = new Date()) {
  const labeled = tickets.map((ticket) => ({ ...ticket, risk: riskLabel(ticket, now) }));
  const byOwner = new Map();

  for (const ticket of labeled) {
    const current = byOwner.get(ticket.owner) ?? { owner: ticket.owner, count: 0, highestRisk: 0 };
    current.count += 1;
    current.highestRisk = Math.max(current.highestRisk, ticket.risk.score);
    byOwner.set(ticket.owner, current);
  }

  return {
    total: tickets.length,
    blocked: labeled.filter((ticket) => ticket.risk.label === 'Blocked').length,
    slaNear: labeled.filter((ticket) => ticket.risk.label === 'SLA near').length,
    aging: labeled.filter((ticket) => ticket.risk.label === 'Aging').length,
    ownerLoad: [...byOwner.values()].sort((left, right) => {
      if (right.highestRisk !== left.highestRisk) return right.highestRisk - left.highestRisk;
      return right.count - left.count;
    })
  };
}
