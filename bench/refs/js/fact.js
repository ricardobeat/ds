function fact(n, acc) {
  if (n === 0) return acc;
  return fact(n - 1, acc * n);
}
console.log(fact(15, 1));
