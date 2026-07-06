function repeat_n(s, n, acc) {
  if (n === 0) return acc;
  return repeat_n(s, n - 1, acc + s);
}
console.log(repeat_n("ab", 50, "").length);
