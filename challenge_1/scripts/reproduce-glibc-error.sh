#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
challenge_root="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${challenge_root}/.." && pwd)"
challenge_dir="$(basename "${challenge_root}")"

container_name="${CONTAINER_NAME:-glibc-debug-ubuntu18}"
binary_name="${BINARY_NAME:-main-linux-glibc234}"
source_file="${SOURCE_FILE:-main.go}"
binary_path="${challenge_root}/build/${binary_name}"

builder_image="${BUILDER_IMAGE:-golang:1.25-bookworm}"
target_image="${TARGET_IMAGE:-ubuntu:18.04}"

mkdir -p "${challenge_root}/build"

echo "==> Building linux/amd64 binary in ${builder_image}"
docker run --platform linux/amd64 --rm \
  -v "${repo_root}:/src" \
  -w /src \
  "${builder_image}" \
  bash -c "/usr/local/go/bin/go build -o ${challenge_dir}/build/${binary_name} ${source_file}"

echo "==> Binary built at ${binary_path}"
file "${binary_path}" || true

echo "==> Recreating Ubuntu 18.04 debug container: ${container_name}"
docker rm -f "${container_name}" >/dev/null 2>&1 || true
docker run --platform linux/amd64 -d \
  --name "${container_name}" \
  -w /root \
  "${target_image}" \
  sleep infinity >/dev/null

docker cp "${binary_path}" "${container_name}:/root/main"
docker exec "${container_name}" chmod +x /root/main

echo "==> Container glibc version"
docker exec "${container_name}" ldd --version

echo "==> Running /root/main inside ${target_image}"
set +e
run_output="$(docker exec "${container_name}" /root/main 2>&1)"
status=$?
set -e
printf '%s\n' "${run_output}"

echo "==> Dynamic dependency check"
set +e
ldd_output="$(docker exec "${container_name}" ldd /root/main 2>&1)"
set -e
printf '%s\n' "${ldd_output}"

cat <<EOF

Container is still running for interactive debugging.

Enter it with:
  docker exec -it ${container_name} bash

Run the binary inside the container:
  /root/main

Clean up when done:
  docker rm -f ${container_name}

Script exit status from /root/main: ${status}
EOF

if grep -q "GLIBC_2.34" <<<"${run_output}"; then
  echo "Expected GLIBC_2.34 error reproduced."
  exit 0
fi

echo "Expected GLIBC_2.34 error was not reproduced."
exit 1
