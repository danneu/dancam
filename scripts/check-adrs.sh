#!/usr/bin/env bash
# scripts/check-adrs.sh -- validate ADR filenames: {seq}-YYYY-MM-DD-{slug}.md
set -euo pipefail

status=0
fmt='^([0-9]{2})-([0-9]{4}-[0-9]{2}-[0-9]{2})-[a-z0-9]+(-[a-z0-9]+)*\.md$'

for dir in app/docs/design raspi/docs/design; do
  [ -d "$dir" ] || continue
  seqs=()
  dates=()

  for path in "$dir"/*.md; do
    [ -e "$path" ] || continue
    name=$(basename "$path")

    if [[ ! $name =~ $fmt ]]; then
      echo "BAD FORMAT: $dir/$name"
      status=1
      continue
    fi

    seqs+=("${BASH_REMATCH[1]}")
    dates+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}")
  done

  [ ${#seqs[@]} -eq 0 ] && continue

  sorted=$(printf '%s\n' "${seqs[@]}" | sort)
  dups=$(printf '%s\n' "$sorted" | uniq -d)
  [ -n "$dups" ] && {
    echo "DUP SEQ in $dir: $dups"
    status=1
  }

  prev=""
  while read -r s d; do
    [ -n "$prev" ] && [[ "$d" < "$prev" ]] && {
      echo "SEQ/DATE ORDER in $dir: seq $s ($d) precedes $prev"
      status=1
    }
    prev=$d
  done < <(printf '%s\n' "${dates[@]}" | sort)
done

[ $status -eq 0 ] && echo "ADR check OK"
exit $status
