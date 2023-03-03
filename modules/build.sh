#!/bin/bash

set -e

readonly IMAGE_NAME="$REGISTRY/$REPOSITORY-$MODULE:$VERSION"
readonly ARCH_LIST="amd64 arm64"

BUILDARCH=$(arch)
case $BUILDARCH in
aarch64)
  readonly BUILDARCH=arm64
  ;;
x86_64)
  readonly BUILDARCH=amd64
  ;;
*)
  echo "Unsupported $BUILDARCH"
  exit
  ;;
esac

buildah version
date >"$(hostname)"
until sudo docker run --rm -v "/usr/bin:/pwd" -w /tools --entrypoint /bin/sh "ghcr.io/labring-actions/cache:tools-$BUILDARCH" -c "ls -lh && cp -a . /pwd" 2>/dev/null; do
  sleep "$(($(grep -v ^$ -c "$(hostname)") * 2))s"
  date >>"$(hostname)"
done
buildah version

if ! [[ "$VERSION" =~ ^[0-9.]+$ ]]; then
  case $MODULE in
  sealos)
    echo "$VERSION"
    ;;
  *)
    exit
    ;;
  esac
fi
if buildah inspect "$IMAGE_NAME"; then
  exit
fi

case $MODULE in
kubernetes | sealos)
  if ! sealos version --short >/dev/null 2>&1; then
    MOUNT_SEALOS=$(sudo buildah mount "$(sudo buildah from "ghcr.io/labring/sealos:$(
      git ls-remote --refs --sort="-version:refname" --tags "https://github.com/labring/sealos.git" | cut -d/ -f3- | grep -E "^v[0-9.]+$" | head -n 1
    )")")
    sudo cp -a "$MOUNT_SEALOS/usr/bin/sealos" /usr/bin/
  fi
  ;;
esac

sudo buildah login --username "$REPOSITORY_OWNER" --password "$REPOSITORY_TOKEN" "$REGISTRY"

kube_pkgs() {
  local vV=$1
  sudo rm -rf bin images registry
  mkdir -p "images/shim" "bin"
  # cache binary
  for binary in kubectl kubelet kubeadm; do until curl -sLo "bin/$binary" "https://dl.k8s.io/release/$vV/bin/linux/$ARCH/$binary"; do sleep 1; done; done
  # cache image
  if [[ amd64 == "$ARCH" ]]; then
    sudo cp -a bin/kubeadm /usr/bin/
  else
    until sudo curl -sLo /usr/bin/kubeadm "https://dl.k8s.io/release/$vV/bin/linux/amd64/kubeadm"; do sleep 1; done
  fi
  sudo chmod a+x /usr/bin/kubeadm
  kubeadm config images list --kubernetes-version "$vV" >"images/shim/DefaultImageList"
  cat <<EOF >"Dockerfile"
FROM scratch
EOF
  chmod a+x bin/kube* && upx bin/kube*
  sudo sealos build --tag "$MODULE:$vV-$ARCH" --platform "linux/$ARCH" -f Dockerfile .
  sudo tree -L 5
}

runc_pkgs() {
  if ! [ -s libseccomp.tgz ]; then
    until wget -qO- "https://github.com/opencontainers/runc/archive/refs/tags/v$VERSION.tar.gz" | tar -xz; do sleep 1; done
    pushd "runc-$VERSION" >/dev/null
    docker build -t "seccomp/libseccomp:v$VERSION" .
    docker run --rm -v "$PWD:/pwd" -w /pwd --entrypoint /bin/sh "seccomp/libseccomp:v$VERSION" -c "tar -zcf libseccomp.tgz /opt/libseccomp"
    popd >/dev/null
    cp "runc-$VERSION/libseccomp.tgz" .
    sudo rm -rf "runc-$VERSION"
  fi
  sudo tar -xzf libseccomp.tgz
  mkdir lib
  case $ARCH in
  amd64)
    sudo cp -a "opt/libseccomp/lib/libseccomp.so"* lib
    ;;
  *)
    sudo cp -a "opt/libseccomp/$ARCH/lib/libseccomp.so"* lib
    ;;
  esac
  sudo chown -hR 0:0 lib
  tar -czf libseccomp.tar.gz lib
  sudo rm -rf lib opt
}

sealos_pkgs() {
  local vV=$1
  sudo rm -rf bin images registry
  mkdir -p "images/shim" "bin"
  # cache image
  echo "ghcr.io/labring/lvscare:$vV" >"images/shim/DefaultImageList"
  cat <<EOF >"Dockerfile"
FROM scratch
EOF
  sudo sealos build --tag "$MODULE:$vV-$ARCH" --platform "linux/$ARCH" -f Dockerfile .
  sudo tree -L 5
}

Dockerfile() {
  local target_url
  local ALIAS_ARCH
  if ! [ -s modules.txt ]; then
    date >"$(hostname)"
    until wget -qOmodules.txt "https://github.com/$REPOSITORY/raw/main/modules/modules.txt"; do
      sleep "$(($(grep -v ^$ -c "$(hostname)") * 2))s"
      date >>"$(hostname)"
    done
  fi
  case $MODULE in
  docker | moby)
    case $ARCH in
    amd64)
      ALIAS_ARCH=x86_64
      ;;
    arm64)
      ALIAS_ARCH=aarch64
      ;;
    esac
    target_url="https://download.docker.com/linux/static/stable/$ALIAS_ARCH/docker-$VERSION.tgz"
    ;;
  kubernetes)
    target_url="https://github.com/kubernetes/kubernetes/archive/refs/tags/v$VERSION.tar.gz"
    ;;
  *)
    target_url=$(grep "/$MODULE/releases/download/" modules.txt |
      sed -E "s~[0-9][0-9.]+[0-9]~$VERSION~g" |
      sed -E "s~(amd64|arm64)~$ARCH~g")
    ;;
  esac
  case $MODULE in
  cri-o)
    if ! wget -qO"$MODULE.$ARCH" "$target_url"; then
      if ! wget -qO"$MODULE.$ARCH" "$(
        until curl -sL "https://github.com/cri-o/cri-o/releases/tag/v$VERSION"; do sleep 1; done |
          grep 'href="http.://' | sed 's/ /\n/g' | grep 'href="http.://' | awk -F\" '{print $2}' |
          grep ".tar.gz$" | sort | uniq | grep "$MODULE.$ARCH"
      )"; then
        return 89
      fi
    fi
    tar -xzvf "$MODULE.$ARCH" --strip-components=1 cri-o/bin/{conmon,crio,crio-status,pinns}
    tar -zcvf "$MODULE.$ARCH" bin/
    rm -rf bin/
    ;;
  *)
    if ! wget -qO"$MODULE.$ARCH" "$target_url"; then
      return 88
    fi
    ;;
  esac
  # build image
  echo "docker://$IMAGE_NAME-$ARCH" >>"manifest.$MODULE"
  case $MODULE in
  kubernetes)
    kube_pkgs "v$VERSION"
    cat <<EOF >Dockerfile
FROM scratch
COPY --chown=0:0 bin /bin
COPY --chown=0:0 images /images
COPY --chown=0:0 registry /registry
EOF
    ;;
  runc)
    runc_pkgs
    cat <<EOF >Dockerfile
FROM scratch
COPY --chown=0:0 "$MODULE.$ARCH" /modules/$MODULE
COPY --chown=0:0 "libseccomp.tar.gz" /modules/libseccomp.tar.gz
EOF
    ;;
  sealos)
    sealos_pkgs "v$VERSION"
    cat <<EOF >Dockerfile
FROM scratch
COPY --chown=0:0 "$MODULE.$ARCH" /modules/$MODULE
COPY --chown=0:0 registry /registry
EOF
    ;;
  *)
    cat <<EOF >Dockerfile
FROM scratch
COPY --chown=0:0 "$MODULE.$ARCH" /modules/$MODULE
EOF
    ;;
  esac
}

for ARCH in $ARCH_LIST; do
  if ! sudo buildah pull --policy always --arch "$ARCH" "$IMAGE_NAME-$ARCH" >/dev/null 2>&1; then
    if ! Dockerfile; then
      continue
    fi
    if sudo find . -type f -exec file {} \; | grep -E "(executable|/ld-)" | awk -F: '{print $1}' | grep -vE "\.so" >.files; then
      xargs <.files sudo chmod a+x
      sudo rm -f .files
    fi
    sudo buildah build --network host --pull \
      --arch "$ARCH" \
      --label "org.opencontainers.image.source=https://github.com/$REPOSITORY" \
      --label "org.opencontainers.image.description=$MODULE-$VERSION container image" \
      --label "org.opencontainers.image.licenses=MIT" \
      --tag "$IMAGE_NAME-$ARCH" \
      "."
    until sudo buildah push "$IMAGE_NAME-$ARCH"; do sleep 1; done
  fi
done

if [ -s "manifest.$MODULE" ]; then
  cat "manifest.$MODULE"
  for ARCH in $ARCH_LIST; do
    if sudo buildah images "$IMAGE_NAME-$ARCH" >/dev/null 2>&1; then
      echo "docker://$IMAGE_NAME-$ARCH"
    fi
  done | xargs sudo buildah manifest create --all "$IMAGE_NAME"
  sudo buildah manifest push "$IMAGE_NAME" "docker://$IMAGE_NAME"
  rm -f "manifest.$MODULE"
fi

sudo buildah logout "$REGISTRY"
sudo buildah images
sudo buildah umount --all
