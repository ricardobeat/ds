function build_arr(n, i, acc) {
  if (i === n) return acc;
  return build_arr(n, i + 1, acc.concat(i * 2));
}
function sum_arr(arr, i, acc) {
  if (i === arr.length) return acc;
  return sum_arr(arr, i + 1, acc + arr[i]);
}
const arr = build_arr(1000, 0, []);
console.log(sum_arr(arr, 0, 0));
