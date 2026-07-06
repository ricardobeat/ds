local function fold(arr, f, i, acc)
  if i == #arr then return acc end
  return fold(arr, f, i + 1, f(acc, arr[i + 1]))
end
local nums = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
local sum_sq = fold(nums, function(a, b) return a + b * b end, 0, 0)
print(sum_sq)
