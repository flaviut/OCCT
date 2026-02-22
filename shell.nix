{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  inputsFrom = [ pkgs.opencascade-occt ];
  packages = [
    pkgs.ccache
    pkgs.freetype
    pkgs.gdb
    pkgs.llvmPackages_18.clang-tools
    pkgs.nixfmt
    pkgs.treefmt
  ];
  CMAKE_EXPORT_COMPILE_COMMANDS = "ON";
  shellHook = ''
    (
      remote=ssh-ng://flaviu@192.168.86.244
      if nix store info --store "$remote" >/dev/null 2>&1; then
        nix copy --to "$remote" "$NIX_CC" $buildInputs $nativeBuildInputs
      fi
    )
  '';
}
