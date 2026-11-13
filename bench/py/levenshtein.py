# Edit distance between each name and the 40 that follow it of examples/names.txt, with the two-row dynamic programme.
docs = [line.strip() for line in open('examples/names.txt') if line.strip()]

def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        cur = [i] + [0] * len(b)
        for j in range(1, len(b) + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        prev = cur
    return prev[len(b)]

total = 0
longest = 0
for i in range(len(docs) - 40):
    for k in range(1, 41):
        d = levenshtein(docs[i], docs[i + k])
        total += d
        longest = max(longest, d)
print(total, longest)
