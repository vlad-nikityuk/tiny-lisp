# Conway's game of life on a 80 x 80 torus, 100 generations from a random start.
state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

h = 80
w = 80
grid = [[1 if rand() < 0.3 else 0 for _ in range(w)] for _ in range(h)]

def step(g):
    new = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            n = 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dy != 0 or dx != 0:
                        n += g[(y + dy) % h][(x + dx) % w]
            if n == 3 or (n == 2 and g[y][x] == 1):
                new[y][x] = 1
    return new

for generation in range(100):
    grid = step(grid)
alive = 0
checksum = 0
for y in range(h):
    for x in range(w):
        alive += grid[y][x]
        checksum += grid[y][x] * (y * w + x)
print(alive, checksum)
