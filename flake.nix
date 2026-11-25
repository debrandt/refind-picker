{
  description = "A rEFInd boot picker in front of systemd-boot for PCs with several NixOS installs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosModules = {
        refind-picker = ./module.nix;
        default = self.nixosModules.refind-picker;
      };

      packages.${system} = {
        refind-nixos-entry = import ./generator.nix { inherit pkgs; };
        default = self.packages.${system}.refind-nixos-entry;
      };

      checks.${system} = import ./tests {
        inherit pkgs nixpkgs;
        module = self.nixosModules.refind-picker;
        generator = self.packages.${system}.refind-nixos-entry;
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
