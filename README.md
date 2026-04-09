# claude-vm

A Nix flake that boots a headless QEMU VM with
[claude-code](https://github.com/sadjow/claude-code-nix) installed. Your current
directory is mounted into the VM at `/workspace`.

## Usage

```bash
nix run github:solomon-b/claude-vm
nix run github:solomon-b/claude-vm -- --dangerously-skip-permissions
nix run github:solomon-b/claude-vm -- --model sonnet
nix run github:solomon-b/claude-vm -- -p "fix the tests"
```

Or clone and run locally:

```bash
nix run .
```

All flags after `--` are forwarded to claude-code inside the VM.

## What's inside

- NixOS VM: 4GB RAM, 4 cores, serial console
- Packages: `claude-code`, `git`, `curl`, `vim`
- 9p shared directory: host CWD mounted read-write at `/workspace`
- Auto-login as `root` user, claude-code launches automatically

## Exit

Press `Ctrl-A X` to quit QEMU. When Claude exits normally, the VM shuts down
automatically. Run with `-c` to continue the last conversation.

## Extending in a downstream flake

The flake exposes a `lib.<system>.mkClaudeVm` helper so downstream flakes can
build their own flavor of `claude-vm` by supplying a list of extra NixOS modules
/ packages. The helper handles the guest system, `virtualisation.host.pkgs`, and
the CLI-argument wrapper script for you.

Below is an example of a downstream flake that adds a Rust toolchain
(`cargo`, `rust-analyzer`, etc.) to the guest so Claude can work on Rust
projects inside the VM:

```nix
{
  description = "claude-vm with a Rust toolchain";

  inputs.claude-vm.url = "github:solomon-b/claude-vm";

  outputs =
    { self, claude-vm }:
    let
      hostSystem = "x86_64-linux";
    in
    {
      packages.${hostSystem}.rust = claude-vm.lib.${hostSystem}.mkClaudeVm {
        name = "claude-vm-rust";
        modules = [
          (
            { pkgs, ... }:
            {
              virtualisation.diskSize = 1024 * 50; # 50 GiB, for Rust build space

              environment.systemPackages = with pkgs; [
                cargo
                clippy
                rustc
                rustfmt
                rust-analyzer
                stdenv.cc # linker for `cargo build`
              ];
            }
          )
        ];
      };
    };
}
```

Save this into a directory separate to your Rust project (as that could contain
an existing `flake.nix`) and run it with:

```sh
nix run ~/claude-vm-template#rust
```

Claude Code will boot into a VM with the full Rust toolchain on `PATH`.

For advanced users only: should you wish to have finer control over the
`nixosSystem` construction, import the `nixosModules.default` module directly
and configure the `virtualisation.host.pkgs` yourself.

## Non-native users (e.g. darwin)

Make sure you have an external builder set up, or use
[Determinate Nix](https://determinate.systems) with the
[`native-linux-builder`](https://determinate.systems/blog/changelog-determinate-nix-384/)
(Page might be out of date) feature enabled, otherwise you will not be able to
build the NixOS VM.
