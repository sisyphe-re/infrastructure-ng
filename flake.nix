{
  description = "Sisyphe system configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    vm.url = "github:sisyphe-re/VM";
    rgrunbla-pkgs.url = "github:rgrunbla/Flakes";
  };

  outputs = { self, nixpkgs, sops-nix, rgrunbla-pkgs, vm }: {
    devShell.x86_64-linux = with import nixpkgs { system = "x86_64-linux"; };
      let
        my_python = pkgs.python3.override {
          packageOverrides = self: super: {
            django = super.django_3;
          };
        };
        django-celery-beat = (my_python.pkgs.toPythonModule
          rgrunbla-pkgs.packages.x86_64-linux.django-celery-beat);
        customPython = pkgs.python3.withPackages (p: [
          p.libvirt
          p.psycopg2
          p.daphne
          p.celery
          p.cryptography
          p.markdown
          p.djangorestframework
          p.python-crontab
          p.django-timezone-field
          django-celery-beat
        ]);
      in
      mkShell {
        buildInputs = [ nixpkgs-fmt customPython ];

        shellHook = ''
          export DB_NAME="sisyphe.db3";
          export DJANGO_HOST="127.0.0.1";
          export DJANGO_SECRET_KEY="toto";
          #python sisyphe/manage.py makemigrations
          #python sisyphe/manage.py migrate
          #python sisyphe/manage.py runserver
        '';
      };
    nixosModules.sisyphe = { pkgs, ... }@args:
      import ./modules/sisyphe (args // { inherit vm rgrunbla-pkgs; });
    nixosModule = self.nixosModules.sisyphe;
  };
}
