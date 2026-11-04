---
name: caesar-cipher
description: Build a self-contained Julia command-line Caesar cipher encoder and decoder when requested.
---

# Build instructions

Return exactly one complete Julia source file as plain text, with no Markdown fences or commentary. Use only Julia standard libraries. The program must not execute shell commands, access the network, or write files.

Implement `julia main.jl encode|decode SHIFT TEXT`. Require exactly three arguments except for `--help`; treat TEXT as one argument (users quote spaces), including an empty string. SHIFT must be a decimal integer matching `[+-]?[0-9]+`; accept negative and arbitrarily large shifts. Reduce modulo 26 before applying it, reversing the direction for decode without integer overflow.

Rotate only ASCII `A`–`Z` and `a`–`z`, preserving case; copy all other characters, including non-ASCII, unchanged. Print the transformed text followed by a newline on stdout.

For `--help` alone, print useful usage and exit successfully. For missing or extra arguments, unknown modes, or invalid SHIFT, print a clear error and usage to stderr, exit nonzero, and avoid stack traces.
