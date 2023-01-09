#!/bin/bash
case $ARCH in
amd64)
  ALIAS_ARCH=x86_64
  ;;
arm64)
  ALIAS_ARCH=aarch64
  ;;
esac
set -ex
until sudo docker run --rm -v "/usr/bin:/pwd" -w /tools --entrypoint /bin/sh "ghcr.io/labring-actions/cache:tools-amd64" -c "cp -au buildah /pwd"; do sleep 5; done 2>/dev/null

readonly -A REPOS=(
  [HELM]=helm/helm
  [YQ]=mikefarah/yq
  [SHELLCHECK]=koalaman/shellcheck
)

for name in ${!REPOS[*]}; do
  export "$name"="$(
    until curl -sL "https://api.github.com/repos/${REPOS[$name]}/tags" | yq '.[].name' | grep -E "^v.+$" 2>/dev/null; do sleep 3; done |
      grep -E "v[0-9.]+$" |
      head -n 1 |
      cut -dv -f2
  )"
done

image_tag="tools-$ARCH"
pushd "$(mktemp -d)" >/dev/null
for name in ${!REPOS[*]}; do echo "echo $name=v\$$name >>/tmp/$image_tag"; done | bash
sort "/tmp/$image_tag" >.versions
FROM_DIFF=$(sudo buildah from "$REGISTRY/$REPOSITORY:$image_tag" 2>/dev/null || true)
if ! sudo diff .versions "$(sudo buildah mount "$FROM_DIFF")"/tools/.versions; then
  until curl -sL "https://get.helm.sh/helm-v$HELM-linux-$ARCH.tar.gz" | tar -zx "linux-$ARCH/helm" --strip-components=1 2>/dev/null; do sleep 3; done
  until curl -sLo yq "https://github.com/mikefarah/yq/releases/download/v$YQ/yq_linux_$ARCH" 2>/dev/null; do sleep 3; done
  until curl -sL "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK/shellcheck-v$SHELLCHECK.linux.$ALIAS_ARCH.tar.xz" |
    tar xJ "shellcheck-v$SHELLCHECK/shellcheck" --strip-components=1 2>/dev/null; do sleep 3; done
  until curl -sLo buildah "https://github.com/labring-actions/cluster-image/releases/download/depend/buildah.linux.$ARCH" 2>/dev/null; do sleep 3; done
  find . -type f -exec file {} \; | grep -E "(executable,|/ld-)" | awk -F: '{print $1}' | grep -vE "\.so" | while IFS='' read -r elf; do sudo chmod a+x "$elf"; done
  cat <<EOF >"/tmp/$image_tag"
FROM alpine:3.17
COPY . /tools
EOF
  until docker buildx build \
    --platform "linux/$ARCH" \
    --label "org.opencontainers.image.source=https://github.com/$REPOSITORY" \
    --label "org.opencontainers.image.description=helm-v$HELM,yq-v$YQ container image" \
    --label "org.opencontainers.image.licenses=MIT" \
    --push \
    -t "$REGISTRY/$REPOSITORY:$image_tag" \
    -f "/tmp/$image_tag" \
    . 2>/dev/null; do sleep 3; done
fi
popd >/dev/null
sudo buildah umount "$FROM_DIFF" >/dev/null || true

docker images "$REGISTRY/$REPOSITORY"
