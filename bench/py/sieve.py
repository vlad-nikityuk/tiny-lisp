# The sieve of Eratosthenes up to 2500000: how many primes, and their sum.
n = 2500000
is_prime = [1] * (n + 1)
is_prime[0] = 0
is_prime[1] = 0
i = 2
while i * i <= n:
    if is_prime[i]:
        for j in range(i * i, n + 1, i):
            is_prime[j] = 0
    i += 1
count = 0
total = 0
for k in range(n + 1):
    if is_prime[k]:
        count += 1
        total += k
print(count, total)
