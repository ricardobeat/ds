local function build_arr(n, i, acc)
  if i == n then return acc end
  acc[#acc + 1] = i * 2
  return build_arr(n, i + 1, acc)
end
local function sum_arr(arr, i, acc)
  if i == #arr then return acc end
  return sum_arr(arr, i + 1, acc + arr[i + 1])
end
local arr = build_arr(1000, 0, {})
print(sum_arr(arr, 0, 0))
