# k-means with k = 4 on 3000 points from four blobs, 80 iterations.
import math

state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

k = 4
centers = [[-3.0, -3.0], [3.0, -3.0], [-3.0, 3.0], [3.0, 3.0]]
points = []
for i in range(3000):
    c = centers[i % k]
    points.append([c[0] + (rand() - 0.5) * 4, c[1] + (rand() - 0.5) * 4])

cent = [points[0][:], points[1][:], points[2][:], points[3][:]]
for it in range(80):
    sums = [[0.0, 0.0] for _ in range(k)]
    counts = [0] * k
    inertia = 0.0
    for p in points:
        best = 0
        best_d = 1e18
        for c in range(k):
            dx = p[0] - cent[c][0]
            dy = p[1] - cent[c][1]
            d = dx * dx + dy * dy
            if d < best_d:
                best_d = d
                best = c
        sums[best][0] += p[0]
        sums[best][1] += p[1]
        counts[best] += 1
        inertia += best_d
    for c in range(k):
        if counts[c] > 0:
            cent[c] = [sums[c][0] / counts[c], sums[c][1] / counts[c]]
print(*counts, math.floor(inertia * 10000), math.floor(cent[0][0] * 1000000), math.floor(cent[3][1] * 1000000))
