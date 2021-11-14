{
  description = "Sisyphe system configuration";

  inputs =
    {
      nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
      sops-nix.url = github:Mic92/sops-nix;
      vm.url = github:sisyphe-re/VM;
      rgrunbla-pkgs.url = github:rgrunbla/Flakes;
    };

  outputs = { self, nixpkgs, sops-nix, rgrunbla-pkgs, vm }:
    {
      devShell.x86_64-linux =
        with import nixpkgs { system = "x86_64-linux"; };
        let
          py = python3.override {
            packageOverrides = self: super: {
              django = super.django_3;
            };
          };
          customPython = py.withPackages
            (p: [
              p.libvirt
              p.django_3
              p.psycopg2
              p.daphne
              p.celery
              p.cryptography
              p.markdown
              p.djangorestframework
              p.python-crontab
              (python3Packages.toPythonModule rgrunbla-pkgs.packages.x86_64-linux.django-celery-beat)
              (python3Packages.toPythonModule rgrunbla-pkgs.packages.x86_64-linux.django-timezone-field)
            ]);
        in
        mkShell
          {
            buildInputs = [
              nixpkgs-fmt
              customPython
            ];

            shellHook = ''
              export DB_NAME="/home/remy/Sisyphe/infrastructure-ng/sisyphe/sisyphe.db3";
              export DJANGO_HOST="127.0.0.1";
              export DJANGO_SECRET_KEY="toto";
              python sisyphe/manage.py makemigrations
              python sisyphe/manage.py migrate
              python sisyphe/manage.py runserver
            '';
          };
      nixosModules.sisyphe = { pkgs, ... }@args: import ./modules/sisyphe (args // { inherit vm rgrunbla-pkgs; });
      nixosModule = self.nixosModules.sisyphe;
    };
}
