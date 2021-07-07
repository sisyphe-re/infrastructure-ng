{ pkgs, lib, config, ... }:
let
  sshPath = "/srv";
  sshPublicKey = (builtins.getEnv "SSH_PUBLIC_KEY");
  # Additional Environment Variables
  runCampaign = pkgs.writeScriptBin "runCampaign" ''
    #! ${pkgs.nix}/bin/nix-shell
    #! nix-shell -i bash -p git nix gnutar openssh cachix coreutils

    export SSH_PATH="${sshPath}"
    export ARTIFACTS_DIRECTORY="${sshPath}"
    export STREAM_PATH=''${ARTIFACTS_DIRECTORY};
    export HOME=''${RUNTIME_DIRECTORY};
    cd ~/;

    echo "Cloning the campaign repository…";
    git clone ''${REPOSITORY};
    cd $(basename ''${REPOSITORY} .git);

    echo "Building the campaign…";
    nix build -v

    echo "Listing the build artifacts";
    nix-store -qR ./result &> ''${ARTIFACTS_DIRECTORY}/build_artifacts.txt;

    echo "Copying the build artifacts to the binary cache";
    mkdir -p ''${ARTIFACTS_DIRECTORY}/store/ 
    ${pkgs.nixUnstable}/bin/nix copy --to file:''${ARTIFACTS_DIRECTORY}/store/ ./result

    echo "Running the campaign"
    ./result/run &> ''${ARTIFACTS_DIRECTORY}/campaign_run.txt;
  '';
in
{

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "nixFlakes" ''
      exec ${pkgs.nixUnstable}/bin/nix --experimental-features "nix-command flakes" "$@"
    '')
  ];

  nix = {
    binaryCaches = [
      "https://bincache.grunblatt.org"
    ];

    binaryCachePublicKeys = [
      "bincache.grunblatt.org:ktUnzmIdQUSVIyu3XcgdKP6LtocaDGbWrOpVBJ62T4A="
    ];
  };

  services.openssh = {
    enable = true;
    ports = [ 22 ];
  };

  networking.firewall = {
    allowedTCPPorts = [ 22 ];
    enable = true;
  };

  users.users = {
    "root" = {
      openssh.authorizedKeys.keys = [
        sshPublicKey
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMoimzzRayQN8PpaoVd6kQC/Xnkv9H1eLcse92Nrk8AT remy@medina"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILjfNIqw1xgnIc9CaBfxhZtIEu7F/sfNENip9Ou5KZm9 remy@sauron"
      ];
    };
  };

  systemd = {
    services."campaign" = {
      enable = true;
      wantedBy = [ "multi-user.target" ];
      environment = {
        NIX_REMOTE = "daemon";
        NIX_PATH = "nixpkgs=${pkgs.path}";
      };

      serviceConfig = {
        RuntimeDirectory = "campaign";
        RuntimeDirectoryPreserve = true;
        EnvironmentFile = "/etc/sisyphe_secrets";
      };

      script = ''
        ${runCampaign}/bin/runCampaign
      '';
    };
  };

 fileSystems."${sshPath}" = {
    device = "//10.0.2.4/qemu";
    fsType = "cifs";
    options =
      let
        # this line prevents hanging on network split
        automount_opts = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=30s,x-systemd.mount-timeout=30s";

      in
      [ "${automount_opts},credentials=/etc/smb_secrets" ];
  };
  environment.etc = {
    smb_secrets = {
      text = ''
        username=root
        domain=localhost
        password=foobar
      '';
    };
  };
}
