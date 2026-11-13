# Logistic regression on two noisy blobs, full-batch gradient descent, plain floats.
import math

state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

n = 300
xs = []
ys = []
for i in range(n):
    c = i % 2
    cx = 1.0 if c else -1.0
    xs.append([cx + (rand() - 0.5) * 2, cx * 0.5 + (rand() - 0.5) * 2])
    ys.append(c)

w = [0.0, 0.0]
b = 0.0
for epoch in range(2000):
    gw = [0.0, 0.0]
    gb = 0.0
    loss = 0.0
    for x, y in zip(xs, ys):
        z = w[0] * x[0] + w[1] * x[1] + b
        p = 1 / (1 + math.exp(-z))
        loss += -(y * math.log(p) + (1 - y) * math.log(1 - p))
        err = p - y
        gw[0] += err * x[0]
        gw[1] += err * x[1]
        gb += err
    w[0] -= 0.5 * gw[0] / n
    w[1] -= 0.5 * gw[1] / n
    b -= 0.5 * gb / n

correct = 0
for x, y in zip(xs, ys):
    z = w[0] * x[0] + w[1] * x[1] + b
    if (z > 0) == (y == 1):
        correct += 1
print(math.floor(loss / n * 1000000), correct, math.floor(w[0] * 1000000), math.floor(b * 1000000))
