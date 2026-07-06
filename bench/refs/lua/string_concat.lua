local function repeat_n(s, n, acc)
  if n == 0 then return acc end
  return repeat_n(s, n - 1, acc .. s)
end
print(#repeat_n("ab", 50, ""))
