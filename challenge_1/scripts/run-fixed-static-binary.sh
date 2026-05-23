#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
challenge_root="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${challenge_root}/.." && pwd)"
challenge_dir="$(basename "${challenge_root}")"

container_name="${CONTAINER_NAME:-glibc-fixed-ubuntu18}"
binary_name="${BINARY_NAME:-main-linux-static}"
source_file="${SOURCE_FILE:-main.go}"
binary_path="${challenge_root}/build/${binary_name}"

builder_image="${BUILDER_IMAGE:-golang:1.25-bookworm}"
target_image="${TARGET_IMAGE:-ubuntu:18.04}"
host_port="${HOST_PORT:-4444}"
container_port="${CONTAINER_PORT:-4444}"

mkdir -p "${challenge_root}/build"

echo "==> Building static linux/amd64 binary in ${builder_image}"
docker run --platform linux/amd64 --rm \
  -v "${repo_root}:/src" \
  -w /src \
  "${builder_image}" \
  bash -c "CGO_ENABLED=0 GOOS=linux GOARCH=amd64 /usr/local/go/bin/go build -trimpath -ldflags='-s -w' -o ${challenge_dir}/build/${binary_name} ${source_file}"

echo "==> Binary built at ${binary_path}"
file "${binary_path}" || true

echo "==> Recreating Ubuntu 18.04 runtime container: ${container_name}"
docker rm -f "${container_name}" >/dev/null 2>&1 || true
docker run --platform linux/amd64 -d \
  --name "${container_name}" \
  -w /root \
  -p "${host_port}:${container_port}" \
  "${target_image}" \
  sleep infinity >/dev/null

docker cp "${binary_path}" "${container_name}:/root/main"
docker exec "${container_name}" chmod +x /root/main

echo "==> Container glibc version"
docker exec "${container_name}" ldd --version

echo "==> Dynamic dependency check"
set +e
ldd_output="$(docker exec "${container_name}" ldd /root/main 2>&1)"
ldd_status=$?
set -e
printf '%s\n' "${ldd_output}"

if ! grep -q "not a dynamic executable" <<<"${ldd_output}"; then
  echo "Expected a static binary with no dynamic glibc dependency."
  exit 1
fi

echo "==> Starting /root/main inside ${target_image}"
docker exec "${container_name}" sh -c "nohup /root/main >/tmp/main.log 2>&1 &"
sleep 1

echo "==> Process check"
docker exec "${container_name}" sh -c "cat /tmp/main.log && ps -ef | grep '[m]ain'"

echo "==> HTTP check inside the container"
docker exec "${container_name}" bash -c \
  "exec 3<>/dev/tcp/127.0.0.1/${container_port}; printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3; cat <&3"

cat <<EOF

Fixed binary is running in ${container_name}.

Try it from the host:
  curl http://localhost:${host_port}/

Enter the container:
  docker exec -it ${container_name} bash

Run the binary manually inside the container:
  /root/main

Stop and clean up:
  docker rm -f ${container_name}

ldd exit status for the static binary: ${ldd_status}
EOF
