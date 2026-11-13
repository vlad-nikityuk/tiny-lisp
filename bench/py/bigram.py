# A character bigram language model, as in makemore: count pairs over examples/names.txt, score the data with
# add-one smoothing, then sample 4000 names.
import math

state = 20240607
def rand():
    global state
    state = (16807 * state) % 2147483647
    return state / 2147483647

docs = [line.strip() for line in open('examples/names.txt') if line.strip()]
uchars = list('abcdefghijklmnopqrstuvwxyz')
BOS = 26
V = 27

N = [[0] * V for _ in range(V)]
for doc in docs:
    tokens = [BOS] + [uchars.index(ch) for ch in doc] + [BOS]
    for a, b in zip(tokens, tokens[1:]):
        N[a][b] += 1

for epoch in range(20):
    nll = 0.0
    n = 0
    for doc in docs:
        tokens = [BOS] + [uchars.index(ch) for ch in doc] + [BOS]
        for a, b in zip(tokens, tokens[1:]):
            row = N[a]
            p = (row[b] + 1) / (sum(row) + V)
            nll += -math.log(p)
            n += 1
print(n, math.floor(nll / n * 1000000))

chars = 0
checksum = 0
for i in range(4000):
    token = BOS
    length = 0
    while True:
        row = N[token]
        r = rand() * (sum(row) + V)
        acc = 0
        nxt = V - 1
        for j in range(V):
            acc += row[j] + 1
            if r < acc:
                nxt = j
                break
        if nxt == BOS or length == 20:
            break
        token = nxt
        length += 1
        checksum += token * length
    chars += length
print(chars, checksum)
