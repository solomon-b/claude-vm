{
  description = "Headless QEMU VM with claude-code — nix run . -- <flags>";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, claude-code-nix }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ claude-code-nix.overlays.default ];
      };
    in
    {
      nixosConfigurations.claude-vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ({ pkgs, lib, modulesPath, ... }: {
            imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

            # ---------- virtualisation ----------
            virtualisation.graphics = false;
            virtualisation.memorySize = 4096;
            virtualisation.cores = 4;

            virtualisation.sharedDirectories = {
              workspace = {
                source = ''"$WORKSPACE_DIR"'';
                target = "/workspace";
                securityModel = "none";
              };
              config = {
                source = ''"$CLAUDE_VM_CONFIG_DIR"'';
                target = "/run/claude-vm-config";
                securityModel = "none";
              };
            };

            # ---------- boot / console ----------
            boot.kernelParams = [ "console=ttyS0" ];
            boot.loader.grub.enable = false;
            boot.initrd.kernelModules = [ "9p" "9pnet_virtio" ];

            # ---------- user ----------
            users.users.claude = {
              isNormalUser = true;
              home = "/home/claude";
              extraGroups = [ "wheel" ];
            };

            services.getty.autologinUser = "claude";

            # ---------- packages ----------
            nixpkgs.config.allowUnfree = true;
            nixpkgs.overlays = [ claude-code-nix.overlays.default ];
            environment.systemPackages = with pkgs; [
              claude-code
              git
              curl
              vim
            ];

            # ---------- nix flakes in guest ----------
            nix.settings.experimental-features = [ "nix-command" "flakes" ];

            # ---------- login shell launches claude ----------
            programs.bash.interactiveShellInit = ''
              # Only run for the auto-login claude user
              [ "$(whoami)" = "claude" ] || return

              args=()
              if [ -f /run/claude-vm-config/claude-args ]; then
                while IFS= read -r line; do
                  [ -n "$line" ] && args+=("$line")
                done < /run/claude-vm-config/claude-args
              fi

              cd /workspace 2>/dev/null || true
              exec claude "''${args[@]}"
            '';

            # ---------- misc ----------
            networking.hostName = "claude-vm";
            system.stateVersion = "25.05";
          })
        ];
      };

      packages.${system}.default =
        let
          vmBuild = self.nixosConfigurations.claude-vm.config.system.build.vm;
        in
        pkgs.writeShellScriptBin "claude-vm" ''
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

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/claude-vm";
      };
    };
}
