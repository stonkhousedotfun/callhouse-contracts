# scan-v2-contracts.awk -- one Solidity file in, declaration records out.
#
# Emits, for the file named by -v rel=<repo-relative path>:
#   D|<name>|<abstract 0|1>|<kind>|<rel>:<line>|<space-separated base list>
#   R|<name>|<function name>          one per external/public NON-view/pure function carrying `restricted`
#   M|<name>|<function name>          one per external/public NON-view/pure function, restricted or not
#   S|<rel>                           the scan receipt, always last
#
# THE RECEIPT IS LOAD-BEARING. awk does not run END on a file it cannot open; it prints "can't open
# file" and exits 2, and that status is invisible inside a shell loop's command substitution. Without
# a receipt per file, a file that silently fails to open just shrinks the result, and a partial scan
# is indistinguishable from a clean tree. The caller counts receipts and dies on a shortfall. This is
# the same guard export-abis.sh uses for the same reason.
#
# WHAT THIS CANNOT SEE, stated because an undocumented blind spot is how the defect it guards was born:
#   - A declaration whose `contract` keyword is not the first token on its line. The T-159 containment
#     check in export-abis.sh has the same limit and it is written down in that file too.
#   - A `restricted` modifier reached through an alias, or applied by a base's override rather than
#     written at the declaration site.
#   - Anything behind a preprocessor-like construct; Solidity has none, which is why this is tractable.
#   - Assembly that changes visibility. It cannot.
{ buf = buf $0 "\n" }

END {
  # --- strip comments, preserving newlines so line numbers survive -------------------------------
  out = ""; i = 1; n = length(buf); blk = 0
  while (i <= n) {
    two = substr(buf, i, 2); ch = substr(buf, i, 1)
    if (blk) {
      if (two == "*/") { blk = 0; i += 2 } else { if (ch == "\n") out = out "\n"; i++ }
    } else if (two == "/*") { blk = 1; i += 2 }
    else if (two == "//") { while (i <= n && substr(buf, i, 1) != "\n") i++ }
    else { out = out ch; i++ }
  }

  # --- walk declarations --------------------------------------------------------------------------
  n = length(out); i = 1; line = 1
  while (i <= n) {
    ch = substr(out, i, 1)
    if (ch == "\n") { line++; i++; continue }

    # a declaration keyword only counts at the start of a line (see the blind spot note above)
    if (atLineStart(out, i) && match(substr(out, i, 200), /^(abstract[ \t]+)?(contract|interface|library)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      head = substr(out, i, RLENGTH)
      isAbstract = (head ~ /^abstract/) ? 1 : 0
      kind = (head ~ /contract[ \t]/) ? "contract" : ((head ~ /interface[ \t]/) ? "interface" : "library")
      name = head; sub(/^(abstract[ \t]+)?(contract|interface|library)[ \t]+/, "", name)

      # inheritance list: everything between the name and the opening brace
      j = i + RLENGTH; bases = ""
      while (j <= n && substr(out, j, 1) != "{") { bases = bases substr(out, j, 1); j++ }
      sub(/^[ \t\n]*is[ \t\n]+/, "", bases)
      if (bases !~ /^[ \t\n]*$/) {
        gsub(/\([^)]*\)/, "", bases); gsub(/[\n\t]/, " ", bases)
        gsub(/,/, " ", bases); gsub(/  +/, " ", bases)
        sub(/^ +/, "", bases); sub(/ +$/, "", bases)
      } else bases = ""

      # brace-match the body so nested declarations cannot leak into the parent
      depth = 0; k = j; startLine = line
      while (k <= n) {
        c = substr(out, k, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) break }
        k++
      }
      body = substr(out, j, k - j + 1)

      printf "D|%s|%d|%s|%s:%d|%s\n", name, isAbstract, kind, rel, startLine, bases
      emitFns(name, body)

      # advance past the body, counting the newlines we skipped
      seg = substr(out, i, k - i + 1); line += gsub(/\n/, "\n", seg)
      i = k + 1
      continue
    }
    i++
  }
  printf "S|%s\n", rel
}

function atLineStart(s, p,   q) {
  q = p - 1
  while (q >= 1 && (substr(s, q, 1) == " " || substr(s, q, 1) == "\t")) q--
  return (q < 1 || substr(s, q, 1) == "\n")
}

# Emit one M (and possibly R) record per external/public state-changing function in this body.
function emitFns(owner, body,   rest, m, hdr, fname, mods, cut) {
  rest = body
  while (match(rest, /function[ \t\n]+[A-Za-z_][A-Za-z0-9_]*[ \t\n]*\(/)) {
    m = RSTART
    hdr = substr(rest, m)
    fname = hdr; sub(/^function[ \t\n]+/, "", fname); sub(/[^A-Za-z0-9_].*$/, "", fname)
    # the header is everything up to the body brace or the semicolon of an unimplemented declaration
    cut = hdr
    if (match(cut, /[{;]/)) cut = substr(cut, 1, RSTART - 1)
    mods = cut
    if (mods ~ /[ \t\n)]external[ \t\n]/ || mods ~ /[ \t\n)]public[ \t\n]/) {
      if (mods !~ /[ \t\n)]view[ \t\n]/ && mods !~ /[ \t\n)]pure[ \t\n]/) {
        printf "M|%s|%s\n", owner, fname
        if (mods ~ /[ \t\n)]restricted[ \t\n]/) printf "R|%s|%s\n", owner, fname
      }
    }
    rest = substr(rest, m + 8)
  }
}
