# ⚙️ asmrun v5

> ✅ **No existing project file was modified.**

---

<details open>
<summary><b>🚀 What v5 adds</b></summary>

- Architecture coverage: x86-64, i386, ARM64/AArch64, ARM32/Thumb-2, RISC-V 64.
- Platforms: Linux (including WSL) and macOS. macOS stays host-native; cross-compilation is Linux-only by design.
- Cross-builds: --target x86_64 | i386 | aarch64 | armv7 | riscv64, with qemu-user fallback and sysroot detection on Linux.
- Modes: --asm-only, --link-only / --no-run, --keep-build-dir / --keep, --report FILE (JSON), --selftest, --cc CMD.
- Config: .asmrunrc, ASMRUN_FLAGS, ASMRUN_NO_RC, ASMRUN_CC.
- Detection: weighted architecture/syntax/bitness detection, ARM32/Thumb-2 and RISC-V signals, ENTRY(...) parsing, main / _start / start handling.
- Tooling: installs only what the file needs, verifies installs, 32-bit multilib auto-install, cpp fallback for .S when no C compiler driver is available.
- Robustness: noexec-safe temp-directory probing, source/output/report overwrite guards, spaced and dash-prefixed path handling, argument forwarding, isolated selftest environment.

</details>

---

<details>
<summary><b>🔒 Preserved invariants</b></summary>

- POSIX sh, no set -e.
- Native build commands remain the exact manual commands — no -z noexecstack and no --no-warn-rwx-segments.
- [BUILD] and all diagnostics go to stderr; program output stays on stdout.
- Detection overrides remain available.

</details>

---

<details>
<summary><b>🧪 Verified on this host</b></summary>

- sh -n and bash --posix -n pass.
- --selftest: 3 passed, 0 failed (nasm64, gas64, int80).
- Native corpus:
- hello64.asm → hello64
- hello64.s → hello-gas
- intel.s → intel!
- libc.asm → libc works
- cpp.S → cpp works
- hell.asm → Hello World!, exit 128
- env -i version and selftest pass.
- JSON reports validate and contain the expected build commands.
- --asm-only, --link-only, no-extension source collision handling, report/output guards, and temp cleanup tested.

</details>

---

<details>
<summary><b>🚧 Not executable here</b></summary>

- No real cross toolchain or qemu-user installed, so cross paths were tested for command construction and graceful missing-tool handling, not real cross execution.
- No macOS environment, so macOS branches were syntax-checked and fake-tested only.
- No ARM/ARM32/RISC-V hardware, so their actual native selftest samples were not run here.

</details>

---

<details open>
<summary><b>⚡ Quick use:</b></summary>

```bash
./asmrun-v5.sh hello.asm
./asmrun-v5.sh --asm-only -o hello.o hello.asm
./asmrun-v5.sh --target aarch64 --link-only hello.s
./asmrun-v5.sh --report build.json hello.s
./asmrun-v5.sh --selftest
./asmrun-v5.sh --help lists every option.
