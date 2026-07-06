local function make_recs(n, i, acc)
  if i == n then return acc end
  acc[#acc + 1] = {x = i, y = i * 2}
  return make_recs(n, i + 1, acc)
end
local function fold(arr, f, i, acc)
  if i == #arr then return acc end
  return fold(arr, f, i + 1, f(acc, arr[i + 1]))
end
local recs = make_recs(500, 0, {})
print(fold(recs, function(a, r) return a + r.x end, 0, 0))
