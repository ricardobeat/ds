function make_recs(n, i, acc) {
  if (i === n) return acc;
  return make_recs(n, i + 1, acc.concat({x: i, y: i * 2}));
}
function fold(arr, f, i, acc) {
  if (i === arr.length) return acc;
  return fold(arr, f, i + 1, f(acc, arr[i]));
}
const recs = make_recs(500, 0, []);
console.log(fold(recs, (a, r) => a + r.x, 0, 0));
