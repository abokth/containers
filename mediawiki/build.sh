#!/bin/bash

# Copyright 2019 Kungliga Tekniska högskolan
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation files
# (the "Software"), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software,
# and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
# BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
# ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Authors: Alexander Boström, KTH

set -e; set -o pipefail

type >/dev/null mktemp
type >/dev/null buildah
type >/dev/null podman

declare -a tmpcontainers
declare -a tmpfiles
cleanup() {
    buildah rm "${tmpcontainers[@]}" >/dev/null || :
    rm -rf "${tmpfiles[@]}"
}

errx() {
    trap - EXIT
    cleanup
    echo >&2 "$@"
    exit 1
}

onexit() {
    local ec=$? bc="$BASH_COMMAND"
    local -i exitcode=$ec
    trap - EXIT
    cleanup
    if (( $exitcode == 0 )); then exit 0; fi
    echo >&2 "$0: command failed with code $exitcode:" "$bc"
    exit $exitcode
}
trap onexit EXIT

mktmp() {
    local tmpvar="$1"; shift
    local newtmpfile=$(mktemp --suffix=".$tmpvar" "$@")
    [[ -n "$newtmpfile" && -e "$newtmpfile" ]]
    tmpfiles+=("$newtmpfile")
    eval "$tmpvar='$newtmpfile'"
}

repobase="$1"; shift

phpimage=localhost/ubi8-php

testcontainer=$(buildah from "$phpimage"-uploaded) || testcontainer=""
mktmp dnfout
if [[ -n "$testcontainer" ]]; then
    tmpcontainers+=("$testcontainer")
    # Check if there are any updates since this container was created.
    env LC_ALL=en_US.UTF-8 buildah run "$testcontainer" microdnf update >"$dnfout"
fi
if ! fgrep -q "Nothing to do" "$dnfout"; then
    # Start from a fresh UBI, install PHP etc.
    phpcontainer=$(buildah from registry.access.redhat.com/ubi8/ubi-minimal)
    tmpcontainers+=("$phpcontainer")
    buildah run "$phpcontainer" microdnf update
    buildah run "$phpcontainer" microdnf --nodocs install httpd php php-mysqlnd php-gd php-xml php-mbstring
    buildah run "$phpcontainer" microdnf clean all

    # Update the local image.
    buildah commit "$phpcontainer" "$phpimage"

    # Push it.
    podman push "$phpimage" "$repobase"/ubi-php:latest

    # Mark as uploaded
    buildah commit "$phpcontainer" "$phpimage"-uploaded
fi

# now $phpimage should exist and be up to date
phpimageid=$(podman image inspect --format '{{.Id}}' "$phpimage")

for branch in stable lts; do
    case "$branch" in
	stable)
	    major_minor="1.32"
	    patch=".1"
	    ;;
	lts)
	    major_minor="1.31"
	    patch=".1"
	    ;;
    esac

    image=localhost/ubi-mediawiki-"$branch"-"$major_minor$patch"
    imagebase=$(podman image inspect --format '{{.Labels.basedon}}' "$image"-uploaded) || imagebase=""
    if [[ "$imagebase" == "<no value>" || -z "$imagebase" || "$imagebase" != "$phpimageid" ]]; then
	# Build a new image.
	mediawikicontainer=$(buildah from "$phpimage")
	tmpcontainers+=("$mediawikicontainer")

	buildah unshare -- /bin/bash <<EOF
set -e; set -o pipefail
set -x

mnt=\$(buildah mount "$mediawikicontainer")

rm -rf "\$mnt"/var/cache/* "\$mnt"/var/log/*
#du -sh "\$mnt" || :

mkdir -p "\$mnt"/src

# Store tarball inside the container for GPL compliance reasons.
pushd >/dev/null "\$mnt"/src
wget https://releases.wikimedia.org/mediawiki/"$major_minor"/mediawiki-"$major_minor$patch".tar.gz
popd >/dev/null

pushd >/dev/null "\$mnt/var/www"
tar -xf "\$mnt"/src/mediawiki-"$major_minor$patch".tar.gz
mv mediawiki-"$major_minor$patch" mediawiki
chown -R root:apache mediawiki
popd >/dev/null

#du -sh "\$mnt" || :

buildah unmount "$mediawikicontainer"
EOF

	buildah config --label basedon=$phpimageid "$mediawikicontainer"
	buildah config --cmd /usr/bin/httpd --port 80 --workingdir=/root "$mediawikicontainer"
	buildah commit "$mediawikicontainer" "$image"

	# Upload
	for tagname in "$branch"-"$major_minor$patch" "$branch"-"$major_minor".z "$branch"; do
	    # Use podman here because there is no "buildah login".
	    # If this fails, run "podman login" first.
	    podman push "$image" "$repobase"/mediawiki:"$tagname"
	done
	if [[ "$branch" == "stable" ]]; then
	    podman push "$image" "$repobase"/mediawiki:latest
	fi

	buildah commit "$mediawikicontainer" "$image"-uploaded
    fi
done
