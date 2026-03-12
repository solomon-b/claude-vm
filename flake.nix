{
  description = "Headless QEMU VM with claude-code — nix run . -- <flags>";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      claude-code-nix,
    }:
    let
      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # aarch64-darwin -> aarch64-linux, x86_64-darwin -> x86_64-linux
      guestSystemFor = hostSystem: builtins.replaceStrings [ "darwin" ] [ "linux" ] hostSystem;

      mkVM =
        hostSystem:
        let
          guestSystem = guestSystemFor hostSystem;
          hostPkgs = import nixpkgs { system = hostSystem; };
        in
        {
          inherit hostPkgs;
          nixosSystem = nixpkgs.lib.nixosSystem {
            system = guestSystem;
            modules = [
              (
                {
                  pkgs,
                  modulesPath,
                  ...
                }:
                {
                  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

                  # ---------- host / guest plumbing ----------
                  virtualisation = {
                    cores = 4;
                    graphics = false;
                    host = {
                      pkgs = hostPkgs;
                    };
                    memorySize = 4096;
                    sharedDirectories = {
                      config = {
                        securityModel = "none";
                        source = ''"$CLAUDE_VM_CONFIG_DIR"'';
                        target = "/mnt/claude-vm-config";
                      };
                      workspace = {
                        securityModel = "none";
                        source = ''"$WORKSPACE_DIR"'';
                        target = "/workspace";
                      };
                    };
                  };

                  # ---------- boot / console ----------
                  boot = {
                    initrd.kernelModules = [
                      "9p"
                      "9pnet_virtio"
                    ];
                    kernelParams = [ "console=ttyS0" ];
                    loader.grub.enable = false;
                  };

                  # ---------- unprivileged VM user ----------
                  users.users.claude = {
                    isNormalUser = true;
                    home = "/home/claude";
                  };

                  services.getty.autologinUser = "claude";

                  # ---------- 9p mount fixup for cross-platform UID mismatch ----------
                  # On macOS the host uid is 501 while the guest normal user is 1000.
                  # "access=user" makes the 9p client skip generic_permission for the
                  # mounting user so the guest user can read/write regardless of host uid.
                  fileSystems."/workspace" = {
                    device = "workspace";
                    fsType = "9p";
                    options = [
                      "trans=virtio"
                      "version=9p2000.L"
                      "access=user"
                      "nofail"
                    ];
                  };
                  fileSystems."/mnt/claude-vm-config" = {
                    device = "config";
                    fsType = "9p";
                    options = [
                      "trans=virtio"
                      "version=9p2000.L"
                      "access=user"
                      "nofail"
                    ];
                  };

                  # ---------- packages ----------
                  nixpkgs = {
                    config.allowUnfree = true;
                    overlays = [ claude-code-nix.overlays.default ];
                  };
                  environment.systemPackages = with pkgs; [
                    claude-code
                    git
                    curl
                    vim
                  ];

                  # ---------- nix flakes in guest ----------
                  nix.settings.experimental-features = [
                    "nix-command"
                    "flakes"
                  ];

                  # ---------- login shell launches claude ----------
                  programs.bash.interactiveShellInit = ''
                    [ "$(whoami)" = "claude" ] || return

                    args=()
                    if [ -f /mnt/claude-vm-config/claude-args ]; then
                      while IFS= read -r line; do
                        [ -n "$line" ] && args+=("$line")
                      done < /mnt/claude-vm-config/claude-args
                    fi

                    cd /workspace 2>/dev/null || true
                    claude "''${args[@]}"
                    systemctl poweroff -f
                  '';

                  # ---------- misc ----------
                  networking.hostName = "claude-vm";
                  system.stateVersion = "25.05";
                }
              )
            ];
          };
        };
    in
    {
      packages = forAllSystems (
        hostSystem:
        let
          vm = mkVM hostSystem;
          vmBuild = vm.nixosSystem.config.system.build.vm;
        in
        {
          default = vm.hostPkgs.writeShellScriptBin "claude-vm" ''
            CONFIG_DIR=$(mktemp -d)
            trap "rm -rf '$CONFIG_DIR'" EXIT

            # Write all CLI args to a file, one per line
            if [ $# -gt 0 ]; then
              printf '%s\n' "$@" > "$CONFIG_DIR/claude-args"
            else
              touch "$CONFIG_DIR/claude-args"
            fi

            export CLAUDE_VM_CONFIG_DIR="$CONFIG_DIR"
            export WORKSPACE_DIR="$(pwd)"
            exec ${vmBuild}/bin/run-claude-vm-vm
          '';
        }
      );

      apps = forAllSystems (hostSystem: {
        default = {
          type = "app";
          program = "${self.packages.${hostSystem}.default}/bin/claude-vm";
        };
      });
    };
}
