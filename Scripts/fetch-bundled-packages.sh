#!/bin/sh
# Copyright (c) 2026 Twarge LLC.
# SPDX-License-Identifier: Apache-2.0
#
# Downloads the Typst Universe packages Typeset ships, unmodified, into
# Resources/TypstPackages/preview/<name>/<version>/.
#
# The list is every package the sample document imports, plus everything those
# packages import in turn, so a new document renders without a network. Each
# package keeps its own licence; see Resources/Acknowledgements. Run this after
# changing the sample document's imports, then commit the result.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Resources/TypstPackages/preview"
REGISTRY="https://packages.typst.org/preview"

PACKAGES="
cetz-0.3.4
cetz-0.4.1
cetz-0.4.2
cetz-0.5.2
chemformula-0.1.3
diagraph-layout-0.0.1
elembic-1.1.1
finite-0.5.1
fletcher-0.5.8
lilaq-0.6.0
oxifmt-0.2.1
oxifmt-1.0.0
quill-0.7.2
t4t-0.4.3
timeliney-0.4.0
tiptoe-0.4.0
typed-smiles-0.4.0
unify-0.8.1
zero-0.6.1
"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$DEST"
mkdir -p "$DEST"

for package in $PACKAGES; do
    name="${package%-*}"
    version="${package##*-}"
    echo "Fetching $name $version"
    curl --fail --silent --show-error --location \
        --output "$WORK/$package.tar.gz" "$REGISTRY/$package.tar.gz"
    mkdir -p "$DEST/$name/$version"
    tar -xzf "$WORK/$package.tar.gz" -C "$DEST/$name/$version"
    if [ ! -f "$DEST/$name/$version/typst.toml" ]; then
        echo "error: $package has no typst.toml" >&2
        exit 1
    fi
done

echo "Bundled packages are in $DEST"
