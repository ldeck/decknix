{ lib, ... }:

let
  # --- HELPER: Recursive File Scanner ---
  # Recursively find all files with a specific extension in a dir
  files = dir: ext:
    if lib.pathIsDirectory dir then
      let
        allPaths = lib.filesystem.listFilesRecursive dir;
      in
        lib.filter (path: lib.hasSuffix ext (toString path)) allPaths
    else [];

  # Find all .nix files
  nixFiles = dir:
    files dir "nix";

  # --- Import and Trace Helper ---
  # Imports a list of paths, adding a debug context trace for each one
  importPaths = context: type: paths:
    map (path:
      builtins.trace "  [${context}] ${type} + ${toString path}" (import path)
    ) paths;

in
{
  # return functions
  inherit files nixFiles importPaths;
}
