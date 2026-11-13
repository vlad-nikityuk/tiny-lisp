# A 2-8-1 MLP with relu learns XOR by SGD, on the scalar autograd of microgpt (bench/py/value.py).
import math
from value import Value

state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

xs = [[0, 0], [0, 1], [1, 0], [1, 1]]
ys = [0, 1, 1, 0]
n_hidden = 8
w1 = [[Value(rand() * 2 - 1) for _ in range(2)] for _ in range(n_hidden)]
b1 = [Value(0) for _ in range(n_hidden)]
w2 = [Value(rand() * 2 - 1) for _ in range(n_hidden)]
b2 = Value(0)
params = [p for row in w1 for p in row] + b1 + w2 + [b2]

def forward(x):
    h = [sum((wi * xi for wi, xi in zip(row, x)), b).relu() for row, b in zip(w1, b1)]
    return sum((w * hi for w, hi in zip(w2, h)), b2)

for step in range(1200):
    loss = Value(0)
    for x, y in zip(xs, ys):
        diff = forward(x) - y
        loss = loss + diff * diff
    loss = loss * (1 / len(xs))
    for p in params:
        p.grad = 0
    loss.backward()
    for p in params:
        p.data -= 0.05 * p.grad
    if step % 50 == 0:
        print(step, math.floor(loss.data * 1000000))
print(math.floor(loss.data * 1000000), math.floor(forward(xs[1]).data * 1000000))
