# Spectral norm of the infinite matrix A[i][j] = 1 / ((i + j) (i + j + 1) / 2 + i + 1), power method, from the
# Computer Language Benchmarks Game.
import math

def eval_A(i, j):
    return 1.0 / ((i + j) * (i + j + 1) // 2 + i + 1)

def times_u(u):
    n = len(u)
    return [sum(eval_A(i, j) * u[j] for j in range(n)) for i in range(n)]

def times_u_transposed(u):
    n = len(u)
    return [sum(eval_A(j, i) * u[j] for j in range(n)) for i in range(n)]

def times_AtA(u):
    return times_u_transposed(times_u(u))

n = 250
u = [1.0] * n
v = [0.0] * n
for _ in range(10):
    v = times_AtA(u)
    u = times_AtA(v)
vBv = sum(ui * vi for ui, vi in zip(u, v))
vv = sum(vi * vi for vi in v)
print(math.floor(math.sqrt(vBv / vv) * 1000000000))
