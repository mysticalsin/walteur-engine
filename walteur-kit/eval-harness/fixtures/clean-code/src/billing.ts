export function total(items: {price:number}[]): number {
  return items.reduce((s,i)=>s+i.price,0);
}
