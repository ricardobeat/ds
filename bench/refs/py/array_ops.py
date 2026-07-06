def build_arr(n, i, acc):
    if i == n: return acc
    return build_arr(n, i + 1, acc + [i * 2])
def sum_arr(arr, i, acc):
    if i == len(arr): return acc
    return sum_arr(arr, i + 1, acc + arr[i])
arr = build_arr(1000, 0, [])
print(sum_arr(arr, 0, 0))
