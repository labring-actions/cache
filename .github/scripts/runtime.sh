#!/bin/bash

set -ex
until sudo docker run --rm -v "/usr/bin:/pwd" -w /tools --entrypoint /bin/sh "$REGISTRY/$REPOSITORY:tools-amd64" -c "cp -au buildah /pwd"; do sleep 5; done 2>/dev/null

readonly -A REPOS=(
  [RUNC]=opencontainers/runc
)

for name in ${!REPOS[*]}; do
  export "$name"="$(
    until curl -sL "https://api.github.com/repos/${REPOS[$name]}/tags" | yq '.[].name' | grep -E "^v.+$" 2>/dev/null; do sleep 3; done |
      grep -E "v[0-9.]+$" |
      head -n 1 |
      cut -dv -f2
  )"
done

image_tag="runtime-$ARCH"
pushd "$(mktemp -d)" >/dev/null
for name in ${!REPOS[*]}; do echo "echo $name=v\$$name >>/tmp/$image_tag"; done | bash
sort "/tmp/$image_tag" >.versions
FROM_DIFF=$(sudo buildah from "$REGISTRY/$REPOSITORY:$image_tag" 2>/dev/null || true)
if ! sudo diff .versions "$(sudo buildah mount "$FROM_DIFF")"/runtime/.versions; then
  {
    until curl -sL "https://github.com/opencontainers/runc/archive/refs/tags/v$RUNC.tar.gz" | tar -xz 2>/dev/null; do sleep 3; done
    pushd "runc-$RUNC"
    export "$(grep -E "LIBSECCOMP_VERSION=[0-9]" Dockerfile | awk '{print $NF}')"
    if [[ amd64 == "$ARCH" ]]; then
      docker build -t "seccomp/libseccomp:v$LIBSECCOMP_VERSION" .
      docker run --rm -v "$PWD:/pwd" -w /pwd --entrypoint tar "seccomp/libseccomp:v$LIBSECCOMP_VERSION" -zcf "libseccomp-v$LIBSECCOMP_VERSION.tgz" /opt/libseccomp
    else
      until docker run --rm -v "$PWD:/pwd" -w /runtime --entrypoint /bin/sh "$REGISTRY/$REPOSITORY:runtime-amd64" -c "cp -au libseccomp-v$LIBSECCOMP_VERSION.tgz /pwd"; do sleep 60; done 2>/dev/null
    fi
    popd
  }
  cp "runc-$RUNC/libseccomp-v$LIBSECCOMP_VERSION.tgz" .
  sudo rm -rf "runc-$RUNC"
  until curl -sLo runc "https://github.com/opencontainers/runc/releases/download/v$RUNC/runc.$ARCH" 2>/dev/null; do sleep 3; done
  find . -type f -exec file {} \; | grep -E "(executable,|/ld-)" | awk -F: '{print $1}' | grep -vE "\.so" | while IFS='' read -r elf; do sudo chmod a+x "$elf"; done
  cat <<EOF >"/tmp/$image_tag"
FROM alpine:3.17
COPY . /runtime
EOF
  until docker buildx build \
    --platform "linux/$ARCH" \
    --label "org.opencontainers.image.source=https://github.com/$REPOSITORY" \
    --label "org.opencontainers.image.description=runc-v$RUNC,libseccomp-v$LIBSECCOMP_VERSION container image" \
    --label "org.opencontainers.image.licenses=MIT" \
    --push \
    -t "$REGISTRY/$REPOSITORY:$image_tag" \
    -f "/tmp/$image_tag" \
    . 2>/dev/null; do sleep 3; done
fi
sudo buildah umount "$FROM_DIFF" >/dev/null || true
popd >/dev/null

docker images "$REGISTRY/$REPOSITORY"
