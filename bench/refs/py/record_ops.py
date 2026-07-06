def make_recs(n, i, acc):
    if i == n: return acc
    return make_recs(n, i + 1, acc + [{"x": i, "y": i * 2}])
def fold(arr, f, i, acc):
    if i == len(arr): return acc
    return fold(arr, f, i + 1, f(acc, arr[i]))
recs = make_recs(500, 0, [])
print(fold(recs, lambda a, r: a + r["x"], 0, 0))
