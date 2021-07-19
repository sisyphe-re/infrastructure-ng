{
  description = "Sisyphe system configuration";

  inputs =
    {
      nixpkgs.url = github:NixOS/nixpkgs/nixos-21.05;
      sops-nix.url = github:Mic92/sops-nix;
      django-toolbox.url = github:sisyphe-re/django-toolbox;
    };

  outputs = { self, nixpkgs, sops-nix, django-toolbox }:
    {
      devShell.x86_64-linux =
        with import nixpkgs { system = "x86_64-linux"; };
        let customPython = python3.withPackages
          (p: [
            p.django_3
            p.psycopg2
            p.daphne
            p.celery
            p.cryptography
            p.python-crontab
            (python3Packages.toPythonModule django-toolbox.packages.x86_64-linux.django-celery-beat)
            (python3Packages.toPythonModule django-toolbox.packages.x86_64-linux.django-timezone-field)
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
              cd sisyphe
            '';
          };
      specialArgs = {
        inherit django-toolbox;
      };
      nixosModules.sisyphe = import ./modules/sisyphe { inherit django-toolbox; };
      nixosModule = self.nixosModules.sisyphe;
    };
}
