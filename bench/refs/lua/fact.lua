local function fact(n, acc)
  if n == 0 then return acc end
  return fact(n - 1, acc * n)
end
print(fact(15, 1))
