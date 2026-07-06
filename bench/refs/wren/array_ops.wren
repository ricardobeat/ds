var arr = []
var i = 0
while (i < 1000) {
  arr.add(i * 2)
  i = i + 1
}
var sum = 0
i = 0
while (i < arr.count) {
  sum = sum + arr[i]
  i = i + 1
}
System.print(sum)
