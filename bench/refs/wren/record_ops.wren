var recs = []
var i = 0
while (i < 500) {
  recs.add({"x": i, "y": i * 2})
  i = i + 1
}
var acc = 0
i = 0
while (i < recs.count) {
  acc = acc + recs[i]["x"]
  i = i + 1
}
System.print(acc)
