# Byte-pair encoding as in minbpe: repeatedly merge the most frequent adjacent pair, on the first 1000 names of
# examples/names.txt as token ids (a-z = 0..25, newline = 26). Pair counts live in a flat table, so no dict is needed.
docs = [line.strip() for line in open('examples/names.txt') if line.strip()]
uchars = list('abcdefghijklmnopqrstuvwxyz')

ids = []
for doc in docs[:1000]:
    for ch in doc:
        ids.append(uchars.index(ch))
    ids.append(26)

n_merges = 120
width = 27 + n_merges
merges = []
for m in range(n_merges):
    counts = [0] * (width * width)
    for a, b in zip(ids, ids[1:]):
        counts[a * width + b] += 1
    best = 0
    for k in range(len(counts)):
        if counts[k] > counts[best]:
            best = k
    a = best // width
    b = best % width
    new_id = 27 + m
    out = []
    i = 0
    while i < len(ids):
        if i < len(ids) - 1 and ids[i] == a and ids[i + 1] == b:
            out.append(new_id)
            i += 2
        else:
            out.append(ids[i])
            i += 1
    ids = out
    merges.append(a * 1000 + b)
print(len(ids), sum(merges), merges[0], merges[-1])
