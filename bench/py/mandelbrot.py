# The Mandelbrot set on a 300 x 300 grid: escape times with at most 200 iterations.
def escape_time(cr, ci, max_iter):
    zr = 0.0
    zi = 0.0
    i = 0
    while i < max_iter and zr * zr + zi * zi <= 4.0:
        zr, zi = zr * zr - zi * zi + cr, 2.0 * zr * zi + ci
        i += 1
    return i

size = 300
max_iter = 200
inside = 0
total = 0
for py in range(size):
    for px in range(size):
        i = escape_time(-2.0 + 3.0 * px / size, -1.5 + 3.0 * py / size, max_iter)
        total += i
        if i == max_iter:
            inside += 1
print(inside, total)
