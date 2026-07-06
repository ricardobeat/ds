local function sum_to(n, acc)
  if n == 0 then return acc end
  return sum_to(n - 1, acc + n)
end
print(sum_to(1000000, 0))
