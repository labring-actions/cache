#!/bin/bash

set -ex
until sudo docker run --rm -v "/usr/bin:/pwd" -w /tools --entrypoint /bin/sh "$REGISTRY/$REPOSITORY:tools-amd64" -c "cp -au buildah /pwd"; do sleep 5; done 2>/dev/null

align_kube() {
  local binary=$1 tags_url
  local vKUBE=$2
  case $binary in
  cri-tools)
    tags_url=https://api.github.com/repos/kubernetes-sigs/cri-tools/tags
    ;;
  cri-o)
    tags_url=https://api.github.com/repos/cri-o/cri-o/tags
    ;;
  esac
  [ -s "$binary.tags" ] || until curl -sL "$tags_url" | yq '.[].name' | grep -E "^v.+$" 2>/dev/null; do sleep 3; done >"$binary.tags"
  if grep "^${vKUBE%.*}." "$binary.tags" >/dev/null; then
    grep "^${vKUBE%.*}." "$binary.tags" | head -n 1
  else
    head -n 1 "$binary.tags"
  fi
}

cache_kube() {
  local vKUBE=$1 ARCH=$2
  image_tag="kubernetes-$vKUBE-$ARCH"
  pushd "$(mktemp -d)" >/dev/null
  if ! docker pull "$REGISTRY/$REPOSITORY:$image_tag" >/dev/null; then
    mkdir -p "images/shim" "bin"
    # cache binary
    for binary in kubectl kubelet kubeadm; do until curl -sLo "bin/$binary" "https://storage.googleapis.com/kubernetes-release/release/$vKUBE/bin/linux/$ARCH/$binary" 2>/dev/null; do sleep 3; done; done
    find . -type f -exec file {} \; | grep -E "(executable,|/ld-)" | awk -F: '{print $1}' | grep -vE "\.so" | while IFS='' read -r elf; do sudo chmod a+x "$elf"; done
    # cache image
    cat <<EOF >"Kubefile"
FROM scratch
EOF
    if [[ amd64 == "$ARCH" ]]; then
      cp -a bin/kubeadm .
      ./kubeadm version
    else
      until curl -sLo kubeadm "https://storage.googleapis.com/kubernetes-release/release/$vKUBE/bin/linux/amd64/kubeadm" 2>/dev/null; do sleep 3; done
      chmod a+x kubeadm
    fi
    ./kubeadm config images list --kubernetes-version "$vKUBE" >"images/shim/DefaultImageList"

    until docker run --rm -v "/usr/bin:/pwd" -w /sealos --entrypoint /bin/sh "$REGISTRY/$REPOSITORY:sealos-v$(until curl -sL "https://api.github.com/repos/labring/sealos/tags" | yq '.[].name' | grep -E "^v.+$" 2>/dev/null; do sleep 3; done | grep -E "v[0-9.]+$" | head -n 1 | cut -dv -f2)-amd64" -c "cp -au sealos /pwd"; do sleep 5; done 2>/dev/null
    sudo sealos build -t "kubernetes:$image_tag" --platform "linux/$ARCH" .
    # cache(binary+image)
    sudo chown -R "$(whoami)" .
    cat <<EOF >"/tmp/$image_tag"
FROM scratch
COPY bin /bin
COPY images /images
COPY registry /registry
EOF
    until docker buildx build \
      --platform "linux/$ARCH" \
      --label "org.opencontainers.image.source=https://github.com/$REPOSITORY" \
      --label "org.opencontainers.image.description=kubernetes-$vKUBE container image" \
      --label "org.opencontainers.image.licenses=MIT" \
      --push \
      -t "$REGISTRY/$REPOSITORY:$image_tag" \
      -f "/tmp/$image_tag" \
      . 2>/dev/null; do sleep 3; done
  fi
  popd >/dev/null
}

is_released() {
  local K8S_MD=$1 is_released
  image_tag="kubernetes-$K8S_MD-$ARCH"
  pushd "$(mktemp -d)" >/dev/null
  until curl -sL "https://github.com/kubernetes/kubernetes/raw/master/CHANGELOG/$K8S_MD" 2>/dev/null; do sleep 3; done >.versions
  FROM_DIFF=$(sudo buildah from "$REGISTRY/$REPOSITORY:$image_tag" 2>/dev/null || true)
  if ! sudo diff .versions "$(sudo buildah mount "$FROM_DIFF")/$image_tag"; then
    cat <<EOF >"/tmp/$image_tag"
FROM alpine:3.17
COPY .versions /$image_tag
EOF
    until docker buildx build \
      --platform "linux/$ARCH" \
      --label "org.opencontainers.image.source=https://github.com/$REPOSITORY" \
      --label "org.opencontainers.image.description=$K8S_MD container image" \
      --label "org.opencontainers.image.licenses=MIT" \
      --push \
      -t "$REGISTRY/$REPOSITORY:$image_tag" \
      -f "/tmp/$image_tag" \
      . 2>/dev/null; do sleep 3; done
    is_released=YES
  else
    is_released=NO
  fi
  sudo buildah umount "$FROM_DIFF" >/dev/null || true
  popd >/dev/null
  if [[ $is_released == YES ]]; then
    true
  else
    false
  fi
}

while IFS= read -r vKUBE; do
  cache_kube "$vKUBE" "$ARCH"
  CRICTL=$(align_kube cri-tools "$vKUBE")
  CRIO=$(align_kube cri-o "$vKUBE")
  image_tag="cri-${vKUBE%.*}-$ARCH"
  pushd "$(mktemp -d)" >/dev/null
  cat <<EOF | sort >.versions
crictl-$CRICTL
crio-$CRIO
EOF
  FROM_DIFF=$(sudo buildah from "$REGISTRY/$REPOSITORY:$image_tag" 2>/dev/null || true)
  if ! sudo diff .versions "$(sudo buildah mount "$FROM_DIFF")"/cri/.versions; then
    until curl -sLo "crictl.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL/crictl-$CRICTL-linux-$ARCH.tar.gz" 2>/dev/null; do sleep 3; done
    until curl -sLo "cri-o.tar.gz" "https://github.com/cri-o/cri-o/releases/download/$CRIO/cri-o.$ARCH.$CRIO.tar.gz" 2>/dev/null; do sleep 3; done
    find . -type f -exec file {} \; | grep -E "(executable,|/ld-)" | awk -F: '{print $1}' | grep -vE "\.so" | while IFS='' read -r elf; do sudo chmod a+x "$elf"; done
    cat <<EOF >"/tmp/$image_tag"
FROM alpine:3.17
COPY . /cri
EOF
    until docker buildx build \
      --platform "linux/$ARCH" \
      --label "org.opencontainers.image.source=https://github.com/$REPOSITORY" \
      --label "org.opencontainers.image.description=crictl-$CRICTL,crio-$CRIO container image" \
      --label "org.opencontainers.image.licenses=MIT" \
      --push \
      -t "$REGISTRY/$REPOSITORY:$image_tag" \
      -f "/tmp/$image_tag" \
      . 2>/dev/null; do sleep 3; done
  fi
  sudo buildah umount "$FROM_DIFF" >/dev/null || true
  popd >/dev/null
done < <(if is_released "$K8S_MD"; then
  until curl -sL "https://github.com/kubernetes/kubernetes/raw/master/CHANGELOG/$K8S_MD" 2>/dev/null; do sleep 3; done | grep -E '^- \[v[0-9\.]+\]' | awk -F] '{print $1}' | awk -F[ '{print $NF}'
fi)

docker images "$REGISTRY/$REPOSITORY"
