{
  description = "muster.nvim verification toolchain";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/2fcb964de67fcf60b43471c55d5d99e61a9ccb5a";

  outputs =
    { nixpkgs, ... }:
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
