# Fannkuch-redux from the Computer Language Benchmarks Game: over all permutations of 0..n-1, flip the first k+1
# elements while the first element k is not 0, and count the flips.
def reverse_prefix(a, k):
    i = 0
    while i < k:
        a[i], a[k] = a[k], a[i]
        i += 1
        k -= 1

def rotate_left(a, r):
    first = a[0]
    for i in range(r):
        a[i] = a[i + 1]
    a[r] = first

def fannkuch(n):
    perm1 = list(range(n))
    count = [0] * n
    perm = [0] * n
    max_flips = 0
    checksum = 0
    permutations = 0
    r = n
    while True:
        while r != 1:
            count[r - 1] = r
            r -= 1
        for i in range(n):
            perm[i] = perm1[i]
        flips = 0
        k = perm[0]
        while k != 0:
            reverse_prefix(perm, k)
            flips += 1
            k = perm[0]
        if flips > max_flips:
            max_flips = flips
        checksum += flips if permutations % 2 == 0 else -flips
        permutations += 1
        while True:
            if r == n:
                return checksum, max_flips
            rotate_left(perm1, r)
            count[r] -= 1
            if count[r] > 0:
                break
            r += 1

checksum, max_flips = fannkuch(9)
print(checksum, max_flips)
