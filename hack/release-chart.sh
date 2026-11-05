#!/usr/bin/env bash
# Package and push one chart to the OCI registry, unless its version is already
# published.
#
# helm push has no existence check and no --force, and GHCR allows tag
# overwrite, so pushing a published version would silently replace what tenants
# pull. A published version whose content equals this chart's is therefore
# SKIPPED: a push to main that changes no chart (or only the other chart) must
# not fail the release. A published version whose content DIFFERS fails: two
# PRs that each bumped to the same version both pass the PR check
# (hack/version-bump-check.sh), and the second release must not end green with
# its change never published.
#
# Fails closed: only an explicit "not found" from the registry means the version
# is free. helm show chart also fails on a DNS error or an expired token, and
# treating those as free would push over tenants on a network blip. Run after
# helm registry login — unauthenticated, GHCR answers 403 for absent and
# published tags alike.
#
# Usage: hack/release-chart.sh <chart-dir> <registry-without-oci://>
set -euo pipefail

chart_dir="${1:?usage: release-chart.sh <chart-dir> <registry>}"
registry="${2:?usage: release-chart.sh <chart-dir> <registry>}"
HELM="${HELM:-helm}"

name="$(awk '/^name:/{print $2; exit}' "$chart_dir/Chart.yaml")"
version="$(awk '/^version:/{print $2; exit}' "$chart_dir/Chart.yaml")"
[ -n "$name" ] && [ -n "$version" ] || { echo "cannot read name/version from $chart_dir/Chart.yaml" >&2; exit 1; }

# rc is set before the substitution so set -e cannot end the script on the
# expected failure: `out=$(cmd); rc=$?` never reaches `rc=$?` under -e.
rc=0
out="$("$HELM" show chart "oci://$registry/$name" --version "$version" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  # Compare what is published with what this chart packages to, both as helm
  # package lays them out.
  cmp_dir="$(mktemp -d)"; trap 'rm -rf "$cmp_dir"' EXIT
  mkdir -p "$cmp_dir/published" "$cmp_dir/local" "$cmp_dir/pkg"
  "$HELM" pull "oci://$registry/$name" --version "$version" --untar --untardir "$cmp_dir/published" > /dev/null
  "$HELM" package "$chart_dir" -d "$cmp_dir/pkg" > /dev/null
  tar -xzf "$cmp_dir/pkg/$name-$version.tgz" -C "$cmp_dir/local"
  if diff -r "$cmp_dir/published/$name" "$cmp_dir/local/$name" > "$cmp_dir/diff" 2>&1; then
    echo "$name $version is already published with this content — skipping"
    exit 0
  fi
  echo "$name $version is already published with other content — bump the version in $chart_dir/Chart.yaml; this release was not pushed:" >&2
  head -5 "$cmp_dir/diff" >&2
  exit 1
fi
if ! grep -qiE 'not found|manifest unknown|name unknown' <<<"$out"; then
  echo "cannot determine whether $name $version is published — refusing to push:" >&2
  head -3 <<<"$out" >&2
  exit 1
fi

mkdir -p dist
"$HELM" package "$chart_dir" -d dist
"$HELM" push "dist/$name-$version.tgz" "oci://$registry"
echo "$name $version published"
