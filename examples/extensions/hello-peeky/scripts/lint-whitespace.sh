#!/bin/zsh
# Prints "line:col: severity: message" for each line ending in whitespace.
file="$1"
[[ -f "$file" ]] || { echo "no such file: $file" >&2; exit 2; }
rc=0
n=0
while IFS= read -r line || [[ -n "$line" ]]; do
  n=$((n + 1))
  if [[ "$line" =~ '[[:space:]]+$' ]]; then
    trimmed="${line%%[[:space:]]##}"
    echo "${n}:$(( ${#trimmed} + 1 )): warning: trailing whitespace"
    rc=1
  fi
done < "$file"
exit $rc
