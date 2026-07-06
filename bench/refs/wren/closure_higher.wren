var nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
var sum = 0
var i = 0
while (i < nums.count) {
  sum = sum + nums[i] * nums[i]
  i = i + 1
}
System.print(sum)
