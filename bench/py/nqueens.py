# Count the solutions of the n-queens problem by backtracking with column and diagonal flags.
def solve(row, n, cols, diag1, diag2):
    if row == n:
        return 1
    total = 0
    for c in range(n):
        if cols[c] == 0 and diag1[row + c] == 0 and diag2[row - c + n - 1] == 0:
            cols[c] = 1
            diag1[row + c] = 1
            diag2[row - c + n - 1] = 1
            total += solve(row + 1, n, cols, diag1, diag2)
            cols[c] = 0
            diag1[row + c] = 0
            diag2[row - c + n - 1] = 0
    return total

n = 12
print(solve(0, n, [0] * n, [0] * (2 * n), [0] * (2 * n)))
