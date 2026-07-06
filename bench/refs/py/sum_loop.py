def sum_to(n, acc):
    if n == 0: return acc
    return sum_to(n - 1, acc + n)
print(sum_to(1000000, 0))
