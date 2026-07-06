// Wren has no TCO, so use an explicit iterative loop
var n = 35
var a = 0
var b = 1
while (n > 0) {
  var t = a + b
  a = b
  b = t
  n = n - 1
}
System.print(a)
