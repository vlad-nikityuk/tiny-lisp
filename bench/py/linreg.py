# Fit y = 3x + 1 with two scalar parameters, one Value graph per step (bench/py/value.py).
import math
from value import Value

state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

xs = [i / 10 for i in range(40)]
ys = [3 * x + 1 + (rand() - 0.5) * 0.2 for x in xs]
w = Value(0.0)
b = Value(0.0)

for step in range(1500):
    loss = Value(0)
    for x, y in zip(xs, ys):
        err = w * x + b - y
        loss = loss + err * err
    loss = loss * (1 / len(xs))
    w.grad = 0
    b.grad = 0
    loss.backward()
    w.data -= 0.05 * w.grad
    b.data -= 0.05 * b.grad
print(math.floor(w.data * 1000000), math.floor(b.data * 1000000), math.floor(loss.data * 1000000))
