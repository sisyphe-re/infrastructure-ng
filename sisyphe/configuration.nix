{ pkgs, lib, config, ... }:
let
  sshPath = "/srv";
  sshPublicKey = (builtins.getEnv "SSH_PUBLIC_KEY");
  customEnvironment = {
    NIX_REMOTE = "daemon";
    NIX_PATH = "nixpkgs=${pkgs.path}";
    SSH_PATH = "${sshPath}";
    ARTIFACTS_DIRECTORY = "${sshPath}";
    STREAM_PATH = "${sshPath}";
  };
  # Additional Environment Variables
  runCampaign = pkgs.writeScriptBin "runCampaign" ''
    #! ${pkgs.nix}/bin/nix-shell
    #! nix-shell -i bash -p git nix gnutar openssh cachix coreutils curl

    export HOME=$(eval echo ~''$USER);
    cd ~/;

    echo "Saving the repository to SWH";
    curl -X POST "https://archive.softwareheritage.org/api/1/origin/save/git/url/''${REPOSITORY}";

    echo "Cloning the campaign repository…";
    git clone ''${REPOSITORY};
    cd $(basename ''${REPOSITORY} .git);

    echo "Building the campaign…";
    nix build -v

    echo "Listing the build artifacts";
    nix-store -qR ./result &> ''${ARTIFACTS_DIRECTORY}/build_artifacts.txt;

    echo "Copying the build artifacts to the binary cache";
    mkdir -p ''${ARTIFACTS_DIRECTORY}/store/ 
    ${pkgs.nixUnstable}/bin/nix  --experimental-features nix-command copy --to file:''${ARTIFACTS_DIRECTORY}/store/ ./result

    echo "Running the campaign"
    ./result/run &> ''${ARTIFACTS_DIRECTORY}/campaign_run.txt;
  '';
  finalizeCampaign = pkgs.writeScriptBin "finalizeCampaign" ''
    #! ${pkgs.nix}/bin/nix-shell
    #! nix-shell -i bash -p git nix gnutar openssh cachix coreutils

    export HOME=$(eval echo ~''$USER);
    cd ~/;

    echo "Entering the campaign repository…";
    cd $(basename ''${REPOSITORY} .git);

    echo "Running the campaign post scripts"
    ./result/finalize &> ''${ARTIFACTS_DIRECTORY}/campaign_post.txt;
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
      environment = customEnvironment;
      serviceConfig = {
        EnvironmentFile = "/etc/sisyphe_secrets";
      };
      script = ''
        ${runCampaign}/bin/runCampaign
      '';
    };
    services."campaign-finalize" = {
      environment = customEnvironment;
      serviceConfig = {
        EnvironmentFile = "/etc/sisyphe_secrets";
      };
      script = ''
        ${finalizeCampaign}/bin/finalizeCampaign
      '';
    };

  };

  fileSystems."${sshPath}" = {
    device = "//10.0.2.4/qemu";
    fsType = "cifs";
    options =
      let
        # this line prevents hanging on network split
        automount_opts = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=30s,x-systemd.mount-timeout=30s,vers=3.0";

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
