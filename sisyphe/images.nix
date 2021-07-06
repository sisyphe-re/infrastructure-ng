{ nixosConfiguration ? ./configuration.nix }:

let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  toEval = modules:
    import <nixpkgs/nixos/lib/eval-config.nix> {
      system = pkgs.system;
      modules = [ nixosConfiguration ] ++ modules;
      inherit pkgs;
    };
  modules = {
    standalone = [
      {
        config = {
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
            autoResize = true;
          };

          boot = {
            kernelParams = [ "console=ttyS0" ];
            loader = {
              timeout = 0;
              grub.device = "/dev/xvda";
              grub.configurationLimit = 0;
            };

            initrd = {
              network.enable = false;
              availableKernelModules = [ "virtio_net" "virtio_pci" "virtio_mmio" "virtio_blk" "virtio_scsi" "kvm-amd" "kvm-intel" "xhci_pci" "ehci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
            };
          };

          services.udisks2.enable = false;
        };
      }
    ];
  };
  evals = {
    standalone =
      let
        eval = toEval modules.standalone;
        name = "nixos-${eval.config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
      in
        import <nixpkgs/nixos/lib/make-disk-image.nix> {
          inherit lib name pkgs;
          config = eval.config;
          contents = [];
          diskSize = 8192;
          format = "qcow2";
          postVM = ''
            extension=''${diskImage##*.}
            friendlyName=$out/${name}.$extension
            mv "$diskImage" "$friendlyName"
            diskImage=$friendlyName

            mkdir -p $out/nix-support

            ${pkgs.jq}/bin/jq -n \
              --arg label ${lib.escapeShellArg eval.config.system.nixos.label} \
              --arg system ${lib.escapeShellArg pkgs.stdenv.hostPlatform.system} \
              --arg logical_bytes "$(${pkgs.qemu}/bin/qemu-img info --output json "$diskImage" | ${pkgs.jq}/bin/jq '."virtual-size"')" \
              --arg file "$diskImage" \
              '$ARGS.named' \
              > $out/nix-support/image-info.json
          '';
        };
  };
  scripts = {
    standalone = pkgs.writeScript "run" ''
      #!${pkgs.stdenv.shell}

      file=$(cat ${evals.standalone}/nix-support/image-info.json | ${pkgs.jq}/bin/jq -r .file)
      cp $file ./nixos.qcow2
      chmod u+w nixos.qcow2

      trap "rm -f nixos.qcow2" EXIT
      ${pkgs.qemu}/bin/qemu-system-x86_64 --cpu host --enable-kvm -drive file=nixos.qcow2 -m 4096 -nographic -nic user,hostfwd=tcp::10022-:22,hostfwd=tcp::8000-:8000,hostfwd=tcp::8080-:80
    '';
  };
in
  lib.mapAttrs (name: v: v // { run = scripts.${name}; eval = evals.${name}; modules = modules.${name};}) scripts
