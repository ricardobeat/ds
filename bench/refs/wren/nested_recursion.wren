// Trampolined Ackermann for Wren (no TCO).
// Each frame on the stack is a closure to invoke; the top frame's "resume"
// value is fed to the next frame's arg slot.
var pc = 0
var m = 3
var n = 8
// Encode pending call as: [m, n, resume_flag]
// resume_flag: 0 = call ack(m,n); 1 = feed n+1 to pending caller
// We push frames in reverse and pop to execute
var stack = []
var pendingResult = 0
var stage = 0  // 0 = initial, otherwise returning into top frame
// Simulate using a manual stack of (m, n, await_resume_flag)
stack.add([m, n, false])
while (stack.count > 0) {
  var frame = stack[stack.count - 1]
  m = frame[0]
  n = frame[1]
  var awaiting = frame[2]
  if (awaiting) {
    // We just computed the inner result; it lives in pendingResult.
    // The outer was ack(m, inner) → call ack(m-1, pendingResult)
    stack.removeAt(stack.count - 1)
    stack.add([m - 1, pendingResult, false])
  } else if (m == 0) {
    pendingResult = n + 1
    stack.removeAt(stack.count - 1)
  } else if (n == 0) {
    stack.removeAt(stack.count - 1)
    stack.add([m - 1, 1, false])
  } else {
    // ack(m-1, ack(m, n-1)): first compute inner ack(m, n-1),
    // then re-enter current frame with the result.
    stack[stack.count - 1] = [m, n, true]
    stack.add([m, n - 1, false])
  }
}
System.print(pendingResult)
