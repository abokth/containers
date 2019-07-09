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

centos6image=localhost/centos6-updated

testcontainer=$(buildah from "$centos6image"-uploaded) || testcontainer=""
if [[ -n "$testcontainer" ]]; then
    tmpcontainers+=("$testcontainer")
    # Check if there are any updates since this container was created.
    if env LC_ALL=en_US.UTF-8 buildah run "$testcontainer" yum check-update; then
	need_update=""
    else
	ec=$?
	if (( ec == 100 )); then
	    need_update=yes
	else
	    exit "$ec"
	fi
    fi
fi
if [[ -n "$need_update" ]]; then
    # Start from a fresh CentOS 6, install updates.
    centos6container=$(buildah from centos:centos6)
    tmpcontainers+=("$centos6container")
    buildah run "$centos6container" yum -y update
    buildah run "$centos6container" yum clean all

    # Update the local image.
    buildah commit "$centos6container" "$centos6image"

    # Push it.
    podman push "$centos6image" "$repobase"/centos6-updated:latest

    # Mark as uploaded
    buildah commit "$centos6container" "$centos6image"-uploaded
fi

centos7image=localhost/centos7-updated

testcontainer=$(buildah from "$centos7image"-uploaded) || testcontainer=""
if [[ -n "$testcontainer" ]]; then
    tmpcontainers+=("$testcontainer")
    # Check if there are any updates since this container was created.
    if env LC_ALL=en_US.UTF-8 buildah run "$testcontainer" yum check-update; then
	need_update=""
    else
	ec=$?
	if (( ec == 100 )); then
	    need_update=yes
	else
	    exit "$ec"
	fi
    fi
fi
if [[ -n "$need_update" ]]; then
    # Start from a fresh CentOS 7, install updates.
    centos7container=$(buildah from centos:centos7)
    tmpcontainers+=("$centos7container")
    buildah run "$centos7container" yum -y update
    buildah run "$centos7container" yum clean all

    # Update the local image.
    buildah commit "$centos7container" "$centos7image"

    # Push it.
    podman push "$centos7image" "$repobase"/centos7-updated:latest

    # Mark as uploaded
    buildah commit "$centos7container" "$centos7image"-uploaded
fi

