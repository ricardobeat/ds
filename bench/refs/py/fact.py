def fact(n, acc):
    if n == 0: return acc
    return fact(n - 1, acc * n)
print(fact(15, 1))
