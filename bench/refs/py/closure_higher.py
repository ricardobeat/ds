def fold(arr, f, i, acc):
    if i == len(arr): return acc
    return fold(arr, f, i + 1, f(acc, arr[i]))
nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
sum_sq = fold(nums, lambda a, b: a + b * b, 0, 0)
print(sum_sq)
