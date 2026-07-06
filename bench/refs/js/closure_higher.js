function fold(arr, f, i, acc) {
  if (i === arr.length) return acc;
  return fold(arr, f, i + 1, f(acc, arr[i]));
}
const nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
const sum_sq = fold(nums, (a, b) => a + b * b, 0, 0);
console.log(sum_sq);
