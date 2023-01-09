#!/bin/bash

set -ex

while IFS= read -r vSEALOS; do
  image_tag="sealos-$vSEALOS-$ARCH"
  pushd "$(mktemp -d)" >/dev/null
  if ! docker pull "$REGISTRY/$REPOSITORY:$image_tag" >/dev/null; then
    until curl -sL "https://github.com/labring/sealos/releases/download/$vSEALOS/sealos_${vSEALOS#*v}_linux_$ARCH.tar.gz" | tar -zx 2>/dev/null; do sleep 3; done
    find . -type f -exec file {} \; | grep -E "(executable,|/ld-)" | awk -F: '{print $1}' | grep -vE "\.so" | while IFS='' read -r elf; do sudo chmod a+x "$elf"; done
    cat <<EOF >"/tmp/$image_tag"
FROM alpine:3.17
ADD . /sealos
EOF
    until docker buildx build \
      --platform "linux/$ARCH" \
      --label "org.opencontainers.image.source=https://github.com/$REPOSITORY" \
      --label "org.opencontainers.image.description=sealos-$vSEALOS container image" \
      --label "org.opencontainers.image.licenses=MIT" \
      --push \
      -t "$REGISTRY/$REPOSITORY:$image_tag" \
      -f "/tmp/$image_tag" \
      . 2>/dev/null; do sleep 3; done
  fi
  popd >/dev/null
done < <(until curl -sL "https://api.github.com/repos/labring/sealos/tags" | yq '.[].name' | grep -E "^v.+$" 2>/dev/null; do sleep 3; done)

docker images "$REGISTRY/$REPOSITORY"
