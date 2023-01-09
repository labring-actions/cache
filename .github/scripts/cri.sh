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
until sudo docker run --rm -v "/usr/bin:/pwd" -w /tools --entrypoint /bin/sh "$REGISTRY/$REPOSITORY:tools-amd64" -c "cp -au buildah /pwd"; do sleep 5; done 2>/dev/null

readonly -A REPOS=(
  [CONTAINERD]=containerd/containerd
  [CRIDOCKER]=Mirantis/cri-dockerd
  [DOCKER]=moby/moby
  [DISTRIBUTION]=distribution/distribution
)

for name in ${!REPOS[*]}; do
  export "$name"="$(
    until curl -sL "https://api.github.com/repos/${REPOS[$name]}/tags" | yq '.[].name' | grep -E "^v.+$" 2>/dev/null; do sleep 3; done |
      grep -E "v[0-9.]+$" |
      head -n 1 |
      cut -dv -f2
  )"
done

get_obj() {
  local target=${1?Please input target} filename=${1##*/} obj_path
  pushd "$(mktemp -d)" >/dev/null
  case ${filename%%.*} in
  cri-containerd)
    obj_path=usr/bin
    mkdir -p "$obj_path"
    if false; then
      until curl -sL "https://github.com/containerd/containerd/releases/download/v$CONTAINERD/cri-containerd-$CONTAINERD-linux-$ARCH.tar.gz" | tar -zx -C "$obj_path" --strip-components=3 usr/local/bin 2>/dev/null; do sleep 3; done
      rm -f "$obj_path/crictl" "$obj_path/critest" "$obj_path/ctd-decoder"
      until curl -sL "https://github.com/containerd/containerd/releases/download/v$CONTAINERD/cri-containerd-$CONTAINERD-linux-$ARCH.tar.gz" | tar -zx -C "$obj_path" --strip-components=3 usr/local/sbin 2>/dev/null; do sleep 3; done
      rm -f "$obj_path/runc"
    else
      until curl -sL "https://github.com/containerd/containerd/releases/download/v$CONTAINERD/containerd-$CONTAINERD-linux-$ARCH.tar.gz" | tar -zx -C "$obj_path" --strip-components=1 bin 2>/dev/null; do sleep 3; done
    fi
    MOUNT_RT=$(sudo buildah mount "$(sudo buildah from "$REGISTRY/$REPOSITORY:runtime-$ARCH")")
    sudo cp -a "$MOUNT_RT"/runtime/runc "$obj_path"
    ;;
  cri-dockerd)
    obj_path=cri-dockerd
    mkdir -p "$obj_path"
    if false; then
      until curl -sLo "$obj_path"/cri-dockerd "https://github.com/Mirantis/cri-dockerd/releases/download/v$CRIDOCKER/cri-dockerd-$CRIDOCKER.$ARCH" 2>/dev/null; do sleep 3; done
    else
      until curl -sL "https://github.com/Mirantis/cri-dockerd/releases/download/v$CRIDOCKER/cri-dockerd-$CRIDOCKER.$ARCH.tgz" | tar -zx -C "$obj_path" --strip-components=1 cri-dockerd/cri-dockerd 2>/dev/null; do sleep 3; done
    fi
    until curl -sLo "$target"v125 "https://github.com/Mirantis/cri-dockerd/releases/download/v0.2.6/cri-dockerd-0.2.6.$ARCH.tgz" 2>/dev/null; do sleep 3; done
    ;;
  esac
  sudo chown -hR 0:0 "${obj_path%%/*}"
  find "${obj_path%%/*}" -type f -exec file {} \; | grep -E "(executable,|/ld-)" | awk -F: '{print $1}' | grep -vE "\.so" | while IFS='' read -r elf; do sudo chmod a+x "$elf"; done
  tar -zcf "$target" "${obj_path%%/*}"
  sudo rm -rf "${obj_path%%/*}"
  popd >/dev/null
}

image_tag="cri-$ARCH"
pushd "$(mktemp -d)" >/dev/null
for name in ${!REPOS[*]}; do echo "echo $name=v\$$name >>/tmp/$image_tag"; done | bash
sort "/tmp/$image_tag" >.versions
FROM_DIFF=$(sudo buildah from "$REGISTRY/$REPOSITORY:$image_tag" 2>/dev/null || true)
if ! sudo diff .versions "$(sudo buildah mount "$FROM_DIFF")"/cri/.versions; then
  get_obj "$PWD/cri-containerd.tar.gz"
  get_obj "$PWD/cri-dockerd.tgz"
  # kube 1.16(docker-18.09)
  until curl -sLo docker-18.09.tgz "https://download.docker.com/linux/static/stable/$ALIAS_ARCH/docker-18.09.9.tgz" 2>/dev/null; do sleep 3; done
  # kube 1.17-20(docker-19.03)
  until curl -sLo docker-19.03.tgz "https://download.docker.com/linux/static/stable/$ALIAS_ARCH/docker-19.03.9.tgz" 2>/dev/null; do sleep 3; done
  # kube 1.21-23(docker-20.10), 1.24-26(cri-dockerd)
  until curl -sLo "docker.tgz" "https://download.docker.com/linux/static/stable/$ALIAS_ARCH/docker-$DOCKER.tgz" 2>/dev/null; do sleep 3; done
  until curl -sL "https://github.com/distribution/distribution/releases/download/v$DISTRIBUTION/registry_${DISTRIBUTION}_linux_$ARCH.tar.gz" | tar -zx registry 2>/dev/null; do sleep 3; done
  {
    until sudo docker run --rm -v "$PWD/lib:/pwd" -w /pwd --entrypoint /bin/sh "$REGISTRY/$REPOSITORY:runtime-amd64" -c "tar -xzf /runtime/libseccomp-*.tgz"; do sleep 5; done 2>/dev/null
    pushd lib
    case $ARCH in
    amd64)
      sudo cp -a "opt/libseccomp/lib/libseccomp.so"* .
      ;;
    *)
      sudo cp -a "opt/libseccomp/$ARCH/lib/libseccomp.so"* .
      ;;
    esac
    sudo rm -rf opt
    popd
    sudo chown -hR 0:0 lib
    tar -zcf libseccomp.tar.gz lib
    sudo rm -rf lib
  }
  until curl -sL "https://github.com/labring/cluster-image/releases/download/depend/library-2.5-linux-$ARCH.tar.gz" | tar -zx --strip-components=2 library/bin/conntrack 2>/dev/null; do sleep 3; done
  until curl -sLo lsof "https://github.com/labring/cluster-image/releases/download/depend/lsof-linux-$ARCH" 2>/dev/null; do sleep 3; done
  find . -type f -exec file {} \; | grep -E "(executable,|/ld-)" | awk -F: '{print $1}' | grep -vE "\.so" | while IFS='' read -r elf; do sudo chmod a+x "$elf"; done
  cat <<EOF >"/tmp/$image_tag"
FROM alpine:3.17
COPY . /cri
EOF
  until docker buildx build \
    --platform "linux/$ARCH" \
    --label "org.opencontainers.image.source=https://github.com/$REPOSITORY" \
    --label "org.opencontainers.image.description=containerd-v$CONTAINERD,cridocker-v$CRIDOCKER,docker-v$DOCKER,registry-v$DISTRIBUTION container image" \
    --label "org.opencontainers.image.licenses=MIT" \
    --push \
    -t "$REGISTRY/$REPOSITORY:$image_tag" \
    -f "/tmp/$image_tag" \
    . 2>/dev/null; do sleep 3; done
fi
sudo buildah umount "$FROM_DIFF" "$MOUNT_RT" >/dev/null || true
popd >/dev/null

docker images "$REGISTRY/$REPOSITORY"
