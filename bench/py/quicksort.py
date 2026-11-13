# Quicksort of 150000 random integers, in place, with Lomuto partitioning.
state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

def partition(a, lo, hi):
    pivot = a[hi]
    i = lo
    for j in range(lo, hi):
        if a[j] < pivot:
            a[i], a[j] = a[j], a[i]
            i += 1
    a[i], a[hi] = a[hi], a[i]
    return i

def quicksort(a, lo, hi):
    if lo < hi:
        p = partition(a, lo, hi)
        quicksort(a, lo, p - 1)
        quicksort(a, p + 1, hi)

n = 150000
a = [int(rand() * 1000000) for _ in range(n)]
quicksort(a, 0, n - 1)
ordered = 1
checksum = 0
for i in range(n):
    if i > 0 and a[i - 1] > a[i]:
        ordered = 0
    checksum = (checksum + i * a[i]) % 1000003
print(ordered, checksum, a[0], a[n - 1])
