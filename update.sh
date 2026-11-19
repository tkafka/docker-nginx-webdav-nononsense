#!/usr/bin/env bash
set -Eeuo pipefail

log=$(mktemp "${TMPDIR:-/tmp}/nginx-image-update.log.XXXXXX")
printf 'Release log: %s\n' "$log"
exec 3>&1
exec >>"$log" 2>&1

work=
container=
candidate=
cleanup() {
    if [[ -n "$container" ]]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
    if [[ -n "$candidate" ]]; then docker image rm "$candidate" >/dev/null 2>&1 || true; fi
    if [[ -n "$work" ]]; then rm -rf "$work"; fi
}
trap cleanup EXIT
trap 'printf "Release failed at line %s (exit %s). See %s\n" "$LINENO" "$?" "$log" >&2; exit 1' ERR

cd "$(dirname "${BASH_SOURCE[0]}")"
branch=$(git symbolic-ref --short HEAD)
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo 'Commit or stash tracked changes before releasing.' >&2
    exit 1
fi
git fetch --tags origin "$branch"
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]]; then
    echo 'Synchronize the current branch with origin before releasing.' >&2
    exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/nginx-image-build.XXXXXX")
mkdir "$work/source"
git archive HEAD | tar -x -C "$work/source"

image=tomaskafka/nginx-webdav-nononsense
nginx_version=$(git ls-remote --tags --refs https://github.com/nginx/nginx.git 'release-*' |
    sed -nE 's|.*refs/tags/release-([0-9]+\.[0-9]*[02468]\.[0-9]+)$|\1|p' | sort -V | tail -1)
module_version() {
    git ls-remote --tags --refs "https://github.com/$1.git" 'v*' |
        sed -nE 's|.*refs/tags/v([0-9]+\.[0-9]+(\.[0-9]+)?)$|\1|p' | sort -V | tail -1
}
dav_ext=$(module_version arut/nginx-dav-ext-module)
fancyindex=$(module_version aperezdc/ngx-fancyindex)
headers_more=$(module_version openresty/headers-more-nginx-module)
[[ -n "$nginx_version" && -n "$dav_ext" && -n "$fancyindex" && -n "$headers_more" ]]

previous=$(git tag --list | sed -nE 's/^v?([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | sort -V | tail -1)
release=$nginx_version
if [[ -n "$previous" ]] && [[ "$(printf '%s\n' "$previous" "$release" | sort -V | tail -1)" == "$previous" ]]; then
    release="${previous%.*}.$(( ${previous##*.} + 1 ))"
fi
tag=$release
printf 'nginx %s, DAV ext %s, FancyIndex %s, Headers More %s, WebDAV release %s\n' \
    "$nginx_version" "$dav_ext" "$fancyindex" "$headers_more" "$release"

python3 - "$work/source/Dockerfile" "$nginx_version" "$dav_ext" "$fancyindex" "$headers_more" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
updated = path.read_text()
prefixes = ("ARG NGINX_VER_ARG=", "ENV NGINX_DAV_EXT_VER ", "ENV NGINX_FANCYINDEX_VER ", "ENV HEADERS_MORE_VER ")
for prefix, version in zip(prefixes, sys.argv[2:]):
    updated, count = re.subn(r'^' + re.escape(prefix) + r'[0-9.]+$', prefix + version, updated, flags=re.M)
    if count != 1:
        raise SystemExit(f'Expected one Dockerfile pin for {prefix.strip()}')
path.write_text(updated)
PY

if docker buildx imagetools inspect "$image:$release" >"$work/existing-image" 2>&1; then
    echo "Docker Hub already has $image:$release. Reconcile the release tag before retrying." >&2
    exit 1
fi
if ! grep -qiE 'not found|manifest unknown|name unknown' "$work/existing-image"; then
    cat "$work/existing-image" >&2
    exit 1
fi
candidate="$image:check-$release-$"
docker buildx build --pull --no-cache --platform linux/amd64 --load -t "$candidate" "$work/source"
docker run --rm --platform linux/amd64 --entrypoint nginx "$candidate" -v 2>&1 | grep -F "nginx/$nginx_version"
container=$(docker run -d --rm --platform linux/amd64 -p 127.0.0.1::80 \
    -e WEBDAV_USERNAME=smoketest -e WEBDAV_PASSWORD=smoketest "$candidate")
docker exec "$container" chown abc:abc /data
url="http://$(docker port "$container" 80/tcp)/"
for ((attempt = 0; attempt < 30; attempt++)); do
    response=$(curl --max-time 5 -s -o /dev/null -w '%{http_code}' "$url" || true)
    if [[ "$response" == 401 ]]; then break; fi
    sleep 1
done
if [[ "$response" != 401 ]]; then
    docker logs "$container"
    echo 'WebDAV did not start with authentication.' >&2
    exit 1
fi
response=$(curl --max-time 10 -fsS -u smoketest:smoketest -X PROPFIND -H 'Depth: 1' -o /dev/null -w '%{http_code}' "$url")
[[ "$response" == 207 ]]
printf '%s' webdav-test | curl --max-time 10 -fsS -u smoketest:smoketest -T - "${url}test.txt"
[[ "$(curl --max-time 10 -fsS -u smoketest:smoketest "${url}test.txt")" == webdav-test ]]
curl --max-time 10 -fsS -u smoketest:smoketest -X DELETE "${url}test.txt"

docker buildx build --pull --no-cache --platform linux/amd64,linux/arm64 --push \
    -t "$image:$release" "$work/source"
docker buildx imagetools inspect "$image:$release"

cp "$work/source/Dockerfile" Dockerfile
git add -- Dockerfile
git commit --allow-empty -m "Release $release with refreshed upstream dependencies"
git tag -a "$tag" -m "Release $release"
git push --atomic origin "HEAD:refs/heads/$branch" "refs/tags/$tag"
printf 'Released %s:%s. Log: %s\n' "$image" "$release" "$log"
printf 'Released %s:%s. Log: %s\n' "$image" "$release" "$log" >&3
