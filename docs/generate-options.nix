# Options reference for every decknix module, generated from the real module
# tree rather than a hand-kept list.
#
# The hand-kept list this replaces drifted: it missed 14 option-declaring home
# modules and every darwin module. Evaluating the system exactly as a user's
# flake does (through `mkSystem`, with the same auto-imported darwin and home
# trees) means a new module is documented the moment it is imported, and the
# coverage check below fails if a module declares options but is not imported.
#
# Usage (from the repository root):
#   nix build .#docs-options            # merged JSON for the docs hub page
#   nix build .#checks.<system>.docs-options-coverage
#
{ pkgs, self, inputs }:

let
  lib = pkgs.lib;

  # Evaluation target: the platform decknix supports for tiers 1 and above.
  # Option declarations do not depend on the host running the docs build, so
  # the Linux CI runner evaluates (never builds) the darwin system.
  system = "aarch64-darwin";
  docsUser = "docs";

  evaluated = (self.lib.mkSystem {
    inputs = inputs // { decknix = self; };
    settings = { username = docsUser; hostname = "docs"; inherit system; };
    configDir = ../tests/fixtures/config-empty;
  }).darwinConfigurations.default;

  darwinOptions = evaluated.options;
  # The home-manager user is a submodule. Its bare type has no definitions, so
  # option defaults that read config (home.stateVersion, the username) would
  # fail; extend the type with the user's own definitions from mkSystem, the
  # same modules the real system evaluates for that user.
  homeOptions =
    let
      userType = darwinOptions.home-manager.users.type.nestedTypes.elemType;
      userDefinitions = map (def: def.value.${docsUser})
        (lib.filter (def: def.value ? ${docsUser})
          darwinOptions.home-manager.users.definitionsWithLocations);
      userIdentity = {
        home.username = docsUser;
        home.homeDirectory = "/Users/${docsUser}";
      };
    in
    (userType.substSubModules
      (userType.getSubModules ++ userDefinitions ++ [ userIdentity ])).getSubOptions [ ];

  sourceRoot = toString self;
  modulesRoot = "${sourceRoot}/modules/";

  isOwnDeclaration = decl: lib.hasPrefix modulesRoot (toString decl);
  ownedBy = opt: lib.any isOwnDeclaration opt.declarations;
  isShown = opt: opt.visible == true || opt.visible == "shallow";

  # Declarations are rendered relative to modules/ because the hub page builds
  # source links as `<repo>/blob/main/modules/<declaration>`.
  relativeDeclaration = decl:
    let d = toString decl; in
    if lib.hasPrefix modulesRoot d then lib.removePrefix modulesRoot d else d;

  mkDoc = options: pkgs.nixosOptionsDoc {
    inherit options;
    warningsAreErrors = false;
    transformOptions = opt: opt // {
      visible = isShown opt && ownedBy opt;
      declarations = map relativeDeclaration opt.declarations;
    };
  };

  homeDoc = mkDoc homeOptions;
  darwinDoc = mkDoc darwinOptions;

  docList = options:
    lib.filter (opt: ownedBy opt && isShown opt && !opt.internal)
      (lib.optionAttrSetToDocList options);

  documentedFiles = lib.unique (map relativeDeclaration
    (lib.concatMap (opt: lib.filter isOwnDeclaration opt.declarations)
      (docList homeOptions ++ docList darwinOptions)));

  # Every module file that declares a visible option must be reachable from
  # the evaluated tree. A file that declares options but is never imported
  # (or is only imported by a path the system never takes) shows up here.
  declaringFiles =
    let
      nixFiles = lib.filter (f: lib.hasSuffix ".nix" (toString f))
        (lib.filesystem.listFilesRecursive (self + "/modules"));
      # Plain substring search, not lib.hasInfix: that is a regex match, and
      # libstdc++'s std::regex (Nix on Linux, so the docs CI runner) recurses
      # once per character. On agent-shell.nix (~450KB) it overflows even a
      # 64MB stack; macOS Nix uses libc++ and never shows it.
      # tests/docs-options-regex-free.nix keeps regex out of this file.
      contains = needle: text:
        builtins.replaceStrings [ needle ] [ "" ] text != text;
      declares = f:
        let text = builtins.readFile f; in
        contains "mkOption" text || contains "mkEnableOption" text;
    in
    map relativeDeclaration (lib.filter declares nixFiles);

  # Files that only declare internal or submodule-local options, so they
  # legitimately contribute no visible top-level entry of their own.
  coverageExemptions = [ ];

  undocumentedFiles =
    lib.subtractLists (documentedFiles ++ coverageExemptions) declaringFiles;

in rec {
  json = pkgs.runCommand "decknix-options.json" {
    nativeBuildInputs = [ pkgs.jq ];
  } ''
    home=${homeDoc.optionsJSON}/share/doc/nixos/options.json
    darwin=${darwinDoc.optionsJSON}/share/doc/nixos/options.json
    # A module imported into both scopes (modules/common) declares the same
    # option twice; that is one option. Different declarations under one name
    # would make one of them invisible on the hub page, so they fail the build.
    jq -S -n --slurpfile h "$home" --slurpfile d "$darwin" '
      ($h[0] | map_values(. + {scope: "home"})) as $home
      | ($d[0] | map_values(. + {scope: "darwin"})) as $darwin
      | reduce ($darwin | to_entries[]) as $e ($home;
          if has($e.key) then
            if .[$e.key].declarations == $e.value.declarations
            then .[$e.key].scope = "home+darwin"
            else error("option \($e.key) is declared differently in home and darwin")
            end
          else .[$e.key] = $e.value
          end)' > $out
  '';

  coverage = pkgs.runCommand "decknix-options-coverage" {
    nativeBuildInputs = [ pkgs.jq ];
    undocumented = lib.concatStringsSep "\n" undocumentedFiles;
  } ''
    if [ -n "$undocumented" ]; then
      echo "module files that declare options but are missing from the reference:" >&2
      echo "$undocumented" >&2
      exit 1
    fi
    count=$(jq 'length' ${json})
    files=$(jq '[.[].declarations[]] | unique | length' ${json})
    echo "documented $count options from $files module files" | tee $out
  '';

  inherit documentedFiles declaringFiles undocumentedFiles;
}
