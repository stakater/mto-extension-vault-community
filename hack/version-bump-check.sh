#!/usr/bin/env bash
# Fail when a chart changed against <base> but its Chart.yaml version did not.
#
# The release job skips a version that is already published (it never
# overwrites one), so a chart change merged without a bump would never be
# released — silently. This check runs on the PR, where the bump can still be
# added. A chart that does not exist on <base> yet passes.
#
# Usage: hack/version-bump-check.sh <base-ref> <chart-dir>...
set -euo pipefail

base="${1:?usage: version-bump-check.sh <base-ref> <chart-dir>...}"; shift
git rev-parse --verify --quiet "$base^{commit}" > /dev/null \
  || { echo "base ref $base not found — fetch it first (actions/checkout needs fetch-depth: 0)" >&2; exit 1; }

fail=0
for dir in "$@"; do
  # charts/a/ and charts/a are one chart: with the slash, "$base:$dir/Chart.yaml"
  # was charts/a//Chart.yaml, which git can't find, so a changed chart read as
  # a new one and passed without a bump.
  while [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done
  # A path git can't name in the base (absolute, or a directory that is not
  # there at all) read as a new chart and passed.
  case "$dir" in
    /*) echo "$dir: give the chart directory relative to the repository root" >&2; fail=1; continue ;;
  esac
  if [ ! -d "$dir" ]; then
    if git cat-file -e "$base:$dir" 2>/dev/null; then
      echo "$dir: removed"
    else
      echo "$dir: no such chart directory, here or on $base" >&2; fail=1
    fi
    continue
  fi
  if git diff --quiet "$base...HEAD" -- "$dir"; then
    echo "$dir: unchanged"
    continue
  fi
  if ! base_chart="$(git show "$base:$dir/Chart.yaml" 2>/dev/null)"; then
    # New only when the directory itself is not on the base; a chart whose
    # Chart.yaml can't be read there is an error, not a pass.
    if git cat-file -e "$base:$dir" 2>/dev/null; then
      echo "$dir: exists on $base but has no readable Chart.yaml there" >&2
      fail=1
    else
      echo "$dir: new chart"
    fi
    continue
  fi
  old="$(awk '/^version:/{print $2; exit}' <<<"$base_chart")"
  new="$(awk '/^version:/{print $2; exit}' "$dir/Chart.yaml")"
  if [ "$old" = "$new" ]; then
    echo "$dir: changed but still at version $new — bump Chart.yaml, or it will never be released" >&2
    fail=1
  else
    echo "$dir: $old -> $new"
  fi
done
exit "$fail"
