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
      specialArgs = {
        inherit django-toolbox;
      };
      nixosModules.sisyphe = import ./modules/sisyphe { inherit django-toolbox; } ;
      nixosModule = self.nixosModules.sisyphe;
    };
}
