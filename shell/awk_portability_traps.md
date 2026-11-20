# awk portability traps (gawk, mawk, macOS BWK awk)

Each item passed on at least one awk and failed on another. Seen while porting a Python tool to awk in 2026-10.

## gawk

- **Built-in variable names.** A program global named `RT`, `ARGIND`, `ERRNO`, `FPAT`, `FIELDWIDTHS`, `IGNORECASE`, `PREC`, `PROCINFO`, `ROUNDMODE`, `SYMTAB`, `FUNCTAB`, `TEXTDOMAIN`, `BINMODE` or `LINT` is gawk's variable, with no warning. Each `getline` resets `RT`, so a setting named `RT` became empty under gawk only. Names carried over from Python (`RT`, `NR`, `FS`) are the usual source.
- **A call to an undefined function is a parse error,** also when the call is never reached. A library cannot call a hook that the program does not define.

## mawk 1.3.4 (20200120, Ubuntu 22.04)

- `printf "%d"` clamps at 2^31-1. Use `%.0f`.
- No regex interval expressions (`{n}`). Write the repeats out.
- Each append to a string copies it, so a whole-file buffer is quadratic. Read one line at a time.

## macOS awk (BWK)

- A comparison or `?:` in a `print` or `printf` argument list needs parentheses. `> "file"` parses as a redirection.
- `substr()` measures the whole string on each call, so a whole-file buffer is quadratic.
- `getline var < ""` (an empty file name) is fatal. Guard optional paths.
- `f(P, g(P))`, where `g` first makes the untyped `P` an array, gives `f` an empty copy. gawk and mawk pass the array. Fill the array in its own statement first: `n = g(P); f(P, n)`.

## Two bash traps found in the same work

- **Bracket expressions in `case` patterns.** Inside `[...]`, a `[` followed by `.`, `:` or `=` opens a collating symbol, a class or an equivalence class. A pattern such as `[][.*^]` does not parse, and it matches nothing with no error. `bash -n` passes. Write special characters as quoted alternatives: `'.'|'['|'\'`.
- **Dynamic scope.** A new `local d` in a function hides a global `d` from each function that it calls. Select local names that the callers and the test stubs do not use.

## How to apply

- Run each awk change under gawk and under mawk. A shim directory with `awk -> /usr/bin/mawk` at the front of `PATH` is sufficient.
- Use differential tests: the same input through both, then compare the output.
