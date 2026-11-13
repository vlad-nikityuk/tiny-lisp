# 150 x 150 matrix product with three nested loops, then a checksum.
import math

state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

n = 150
A = [[rand() for _ in range(n)] for _ in range(n)]
B = [[rand() for _ in range(n)] for _ in range(n)]
C = [[0.0] * n for _ in range(n)]
for i in range(n):
    for j in range(n):
        s = 0.0
        for k in range(n):
            s += A[i][k] * B[k][j]
        C[i][j] = s

trace = 0.0
total = 0.0
for i in range(n):
    trace += C[i][i]
    for j in range(n):
        total += C[i][j]
print(math.floor(trace * 1000000), math.floor(total * 1000000))
