{
  description = "muster.nvim verification toolchain";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/2fcb964de67fcf60b43471c55d5d99e61a9ccb5a";
  inputs.mason-nvim = {
    url = "github:mason-org/mason.nvim/2a6940af80375532e5e9e7c1f2fc6319a1b7a69d";
    flake = false;
  };

  outputs =
    { mason-nvim, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          MUSTER_MASON_NVIM_PATH = mason-nvim;
          packages = with pkgs; [
            neovim
            lua51Packages.busted
            lua51Packages.nlua
            stylua
            selene
            lua-language-server
            panvimdoc
            actionlint
            shellcheck
            ripgrep
          ];
        };
      });
    };
}
