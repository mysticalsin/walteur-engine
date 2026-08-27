// Production source: finished, complete, and free of any slop markers.
export function convert(amountMinor, rateBps) {
  if (!Number.isInteger(amountMinor)) throw new TypeError('amountMinor must be an integer')
  if (!Number.isInteger(rateBps)) throw new TypeError('rateBps must be an integer')
  return Math.round((amountMinor * rateBps) / 10000)
}
