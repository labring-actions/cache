#!/bin/bash

set -e

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

multi_versions() {
  local repo=${1?} MAJOR_MATCH=${2:-.+}
  local module="${repo#*/}" version major
  if ! [ -s "tags.$module" ]; then
    date >"$(hostname)"
    until git ls-remote --refs --sort="-version:refname" --tags "https://github.com/$repo.git" | cut -d/ -f3- | grep -E "^v[0-9.]+$"; do
      sleep "$(($(grep -v ^$ -c "$(hostname)") * 2))s"
      date >>"$(hostname)"
    done >"tags.$module"
  fi
  while read -r version; do echo "${version%.*}"; done <"tags.$module" | uniq | grep -E "$MAJOR_MATCH" |
    while read -r major; do
      for tag in $(grep <"tags.$module" "^$major" | head -n 3); do
        if curl -sL "https://github.com/$repo/releases/tag/$tag" | grep '="repo_releases"' >/dev/null; then
          cut -dv -f2 <<<"$tag"
          break
        fi
      done
    done |
    while read -r version; do
      case $module in
      kubernetes)
        echo "  - module: $module"
        echo "    version: ${version%.*}.0"
        ;;
      esac
      echo "  - module: $module"
      echo "    version: $version"
    done
}

echo include: >versions

date >"$(hostname)"
until wget -qO- "https://github.com/$REPOSITORY/raw/main/modules/modules.txt"; do
  sleep "$(($(grep -v ^$ -c "$(hostname)") * 2))s"
  date >>"$(hostname)"
done | grep -v ^# | awk -F/ '{printf("%s/%s\n"),$4,$5}' |
  while read -r repo; do
    module="${repo#*/}"
    case $module in
    docker | moby)
      multi_versions "$repo" "2[4-9].[0-9]"
      ;;
    cri-dockerd)
      multi_versions "$repo"
      ;;
    containerd)
      multi_versions "$repo" "1.[8-9]"
      ;;
    cri-o)
      multi_versions "$repo" "1.[2-9][0-9]"
      ;;
    cri-tools)
      multi_versions "$repo" "1.(1[8-9]|[2-9][0-9])"
      ;;
    kubernetes)
      multi_versions "$repo" "1.(1[8-9]|[2-9][0-9])"
      ;;
    *)
      version="$(
        date >"$(hostname)"
        until curl -fsSL "https://api.github.com/repos/$repo/releases/latest"; do
          sleep "$(($(grep -v ^$ -c "$(hostname)") * 2))s"
          date >>"$(hostname)"
        done | yq .tag_name | cut -dv -f2
      )"
      if [ "$module" = sealos ]; then
        multi_versions "$repo" "(4.[1-9]|[5-9])"
        version=$(git ls-remote --refs --sort="-version:refname" --tags "https://github.com/$repo.git" | cut -d/ -f3- | head -n 1 | cut -dv -f2)
      fi
      echo "  - module: $module"
      echo "    version: $version"
      ;;
    esac
  done >>versions

yq -Pi '.|sort_keys(..)' versions

echo include: >versions.build

yq .include[] versions | while IFS= read -r var; do
  name=$(echo "$var" | awk '{print $1}')
  value=$(echo "$var" | awk '{print $NF}')
  case $name in
  module:)
    module=$value
    ;;
  version:)
    version=$value
    echo "$REGISTRY/$REPOSITORY-$module:$version"
    if ! buildah inspect "$REGISTRY/$REPOSITORY-$module:$version" >/dev/null; then
      {
        echo "  - module: $module"
        echo "    version: $version"
      } >>versions.build
    fi
    ;;
  esac
done

mv versions.build versions

if ! grep version: versions >/dev/null 2>&1; then
  cat <<EOF >versions
include:
  - module: sealos
    version: $(curl -fsSL "https://api.github.com/repos/labring/sealos/releases/latest" | yq .tag_name | cut -dv -f2)
EOF
fi
