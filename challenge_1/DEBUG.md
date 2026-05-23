# Debug Notes

## Ranked Hypotheses

1. The binary is dynamically linked to a newer glibc than the customer's VM has. This is the most likely cause because the runtime error explicitly says `/lib/x86_64-linux-gnu/libc.so.6` is missing `GLIBC_2.34` and `GLIBC_2.32`.

2. The binary was built for the wrong target OS or CPU architecture. This is less likely because the VM is able to load the binary far enough to complain about glibc versions, but it is still a common deployment mistake for Go binaries copied between machines.

## Verification Steps

For hypothesis 1, on the customer's VM I would run:

```sh
ldd ./main
```

If `ldd` lists `/lib/x86_64-linux-gnu/libc.so.6` and missing `GLIBC_*` versions, the binary is dynamically linked to glibc and requires a newer version than the VM provides.

For hypothesis 2, on the customer's VM I would run:

```sh
file ./main
```

If `file` reports a non-Linux binary or the wrong CPU architecture, for example `Mach-O` or `ARM64` on an `x86_64` Linux VM, then the binary was built for the wrong target; if it reports `ELF 64-bit ... x86-64`, then this hypothesis is false.

## Fix

Build the Linux binary with cgo disabled:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o main main.go
```

This keeps the build in Go's internal linker path for this program and produces a static binary instead of one that depends on the builder machine's glibc version.

I tested the fix in a reproducible Docker setup using the scripts in `challenge_1/scripts`. This is the `ldd` output for the bad binary on Ubuntu 18.04:

```text
./main: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found (required by ./main)
./main: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.32' not found (required by ./main)
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007fffff1e0000)
        /lib64/ld-linux-x86-64.so.2 (0x00007fffffdd4000)
```

After compiling without cgo, `ldd` reports:

```text
not a dynamic executable
```

## Lesson

If we need to deploy a Go binary to a Linux machine we do not control, we should ensure it is not dynamically linked; if we control the machine, we can still deploy a dynamic executable, but we need to test it first and install the required dependencies.
