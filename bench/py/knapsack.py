# The 0/1 knapsack problem: 400 items, capacity 6000, one-dimensional dynamic programme.
state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

n = 400
capacity = 6000
weights = [1 + int(rand() * 60) for _ in range(n)]
values = [1 + int(rand() * 100) for _ in range(n)]

best = [0] * (capacity + 1)
for i in range(n):
    for c in range(capacity, weights[i] - 1, -1):
        best[c] = max(best[c], best[c - weights[i]] + values[i])
print(best[capacity], sum(weights), sum(values))
