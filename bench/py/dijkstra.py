# Dijkstra's shortest paths on a 50 x 50 grid of random step costs, with the O(V^2) array version.
state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

w = 50
h = 50
cost = [1 + int(rand() * 9) for _ in range(w * h)]

INF = 1000000000
dist = [INF] * (w * h)
done = [0] * (w * h)
dist[0] = cost[0]
for _ in range(w * h):
    u = -1
    best = INF
    for v in range(w * h):
        if done[v] == 0 and dist[v] < best:
            best = dist[v]
            u = v
    if u == -1:
        break
    done[u] = 1
    x = u % w
    y = u // w
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nx = x + dx
        ny = y + dy
        if 0 <= nx < w and 0 <= ny < h:
            v = ny * w + nx
            if dist[u] + cost[v] < dist[v]:
                dist[v] = dist[u] + cost[v]
print(dist[w * h - 1], sum(dist))
