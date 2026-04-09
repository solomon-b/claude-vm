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

      # NixOS module shared between the built-in VM and downstream consumers.
      # Does NOT set virtualisation.host.pkgs — callers must provide that
      # for their host system so QEMU builds with host-native packages.
      vmModule =
        {
          pkgs,
          modulesPath,
          ...
        }:
        {
          imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

          # Host / guest plumbing
          virtualisation = {
            cores = 4;
            graphics = false;
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

          # Boot / console
          boot = {
            initrd.kernelModules = [
              "9p"
              "9pnet_virtio"
            ];
            kernelParams = [ "console=ttyS0" ];
            loader.grub.enable = false;
          };

          services.getty.autologinUser = "root";

          # Packages
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

          # Nix flakes in guest
          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];

          # Login shell launches claude
          programs.bash.interactiveShellInit = ''
            [ "$(whoami)" = "root" ] || return

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

          # Misc
          networking.hostName = "claude-vm";
          system.stateVersion = "25.05";
        };

      # Build a claude-vm wrapper script for a given host system. Downstream
      # flakes can extend the VM by passing extra NixOS `modules`, without
      # having to re-derive the boilerplate (guest system, host.pkgs, the
      # config-dir/args wrapper shell script, etc.).
      mkClaudeVmFor =
        hostSystem:
        {
          name ? "claude-vm",
          modules ? [ ],
        }:
        let
          guestSystem = guestSystemFor hostSystem;
          hostPkgs = import nixpkgs { system = hostSystem; };
          nixosSystem = nixpkgs.lib.nixosSystem {
            system = guestSystem;
            modules = [
              vmModule
              { virtualisation.host.pkgs = hostPkgs; }
            ]
            ++ modules;
          };
          vmBuild = nixosSystem.config.system.build.vm;
        in
        hostPkgs.writeShellScriptBin name ''
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
          exec ${vmBuild}/bin/run-${nixosSystem.config.system.name}-vm
        '';
    in
    {
      # Expose `mkClaudeVm` per host system so downstream flakes can build
      # a customized claude-vm wrapper with just a list of NixOS modules.
      lib = forAllSystems (hostSystem: {
        mkClaudeVm = mkClaudeVmFor hostSystem;
      });

      packages = forAllSystems (hostSystem: {
        default = mkClaudeVmFor hostSystem { };
      });

      # Expose the raw VM module for downstream flakes that want full control
      # over nixosSystem construction instead of using `lib.mkClaudeVm`.
      # Consumers must also set virtualisation.host.pkgs for their host system.
      nixosModules.default = vmModule;

      apps = forAllSystems (hostSystem: {
        default = {
          type = "app";
          program = "${self.packages.${hostSystem}.default}/bin/claude-vm";
        };
      });
    };
}
