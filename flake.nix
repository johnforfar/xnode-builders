{
  description = "Application builders to run your app seamlessly on XnodeOS.";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    systems.url = "github:nix-systems/default";

    # Rust
    crate2nix = {
      url = "github:nix-community/crate2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Python
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    let
      combine = list: builtins.foldl' (acc: elem: acc // elem) { } list;

      systems = import inputs.systems;
      eachSystem =
        pkgsImport: f:
        combine (
          builtins.map (
            system:
            f {
              inherit system;
              pkgs = import inputs.nixpkgs (
                {
                  inherit system;
                  config.allowUnfree = true;
                }
                // pkgsImport
              );
            }
          ) systems
        );

      defaultModule =
        {
          app,
          nixArgs,
          builder,
        }:
        let
          pkgs = nixArgs.pkgs;
          lib = nixArgs.lib;
          name = app.name;
          description = app.description or "";
          useNetwork = if app.module or { } ? network then app.module.network else true;
          useStorage = if app.module or { } ? storage then app.module.storage else true;
          useUser = if app.module or { } ? user then app.module.user else true;

          system = pkgs.stdenv.hostPlatform.system;
          output = builder {
            inherit system pkgs app;
          };

          cfg = nixArgs.config.services.${name};
          # Fix: condition tests `app.module ? options` (correct) but body called
          # `app.options` (wrong — that attr doesn't exist; options is nested under
          # module). xnode-manager's flake exports `module = { options = ...; }`, so
          # `app.module.options` is the function we want. The `.module` got lost in
          # the body during the May 20 "options rework". Fork-only; revert when
          # upstream Openmesh-Network/xnode-builders main HEAD is fixed.
          appOptions = if app.module or { } ? options then app.module.options (nixArgs // { inherit cfg; }) else { };

          isLeaf = option: option ? does;
          toNixOptions =
            options:
            builtins.mapAttrs (
              _: opt:
              if isLeaf opt then
                lib.mkOption ({ default = null; } // opt.option // { type = lib.types.nullOr opt.option.type; })
              else
                toNixOptions opt
            ) options;
          toNixConfig =
            path:
            builtins.concatMap (
              optName:
              let
                fullPath = path ++ [ optName ];
                opt = lib.getAttrFromPath fullPath nixArgs.options;
                value = lib.getAttrFromPath fullPath nixArgs.config;
              in
              if isLeaf opt then
                lib.optional (value != null) (
                  lib.mkMerge (
                    lib.toList (
                      opt.does {
                        inherit value;
                        service = args: { systemd.services.${name} = args; };
                        config = lib.setAttrByPath [
                          "service"
                          name
                        ];
                        me = lib.setAttrByPath fullPath;
                      }
                    )
                  )
                )
              else
                toNixConfig fullPath
            ) (builtins.attrNames (lib.getAttrFromPath path nixArgs.options));
        in
        {
          options = {
            services.${name} = {
              enable = lib.mkEnableOption "Enable ${name}." // {
                default = true;
              };

              package = lib.mkOption {
                type = lib.types.package;
                default = output.package;
                description = ''
                  ${name} equivalent executable.
                '';
              };

              args = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  cli args to pass to ${name} executable.
                '';
              };
            }
            // (toNixOptions appOptions);
          };

          config = lib.mkIf cfg.enable (
            lib.mkMerge (
              [
                (lib.mkIf useNetwork {
                  systemd.services.${name} = {
                    wants = [ "network-online.target" ];
                    after = [ "network-online.target" ];
                  };
                })
                (lib.mkIf useStorage {
                  systemd.services.${name}.serviceConfig = {
                    WorkingDirectory = "/var/lib/${name}";
                    StateDirectory = name;
                  };
                })
                (lib.mkIf useUser {
                  users.groups.${name} = { };
                  users.users.${name} = lib.mkMerge [
                    {
                      isSystemUser = true;
                      group = name;
                    }
                    (lib.optionalAttrs useStorage {
                      home = "/var/lib/${name}";
                      createHome = true;
                    })
                  ];
                  systemd.services.${name}.serviceConfig = {
                    User = name;
                    Group = name;
                  };
                })
                {
                  systemd.services.${name} = {
                    inherit description;
                    wantedBy = [ "multi-user.target" ];
                    serviceConfig = {
                      ExecStart = "${lib.getExe cfg.package} ${builtins.concatStringsSep " " (builtins.map lib.escapeShellArg cfg.args)}";
                      Restart = lib.mkDefault "on-failure";
                    };
                  };
                }
              ]
              # Fix #2: toNixConfig takes only `path`; the leftover `appOptions`
              # arg from pre-refactor signature caused "expected a list but found
              # a set" because path=appOptions (a set) got passed to
              # getAttrFromPath. appOptions is already merged into
              # nixArgs.options.services.${name} above (line 149), so iterating
              # `services.${name}` finds all options including the app's.
              ++ (toNixConfig [
                "services"
                name
              ])
            )
          );
        };

      defaultDevShellBuildInputs =
        { pkgs }:
        [
          pkgs.git
        ];

      defaultVsCodeExtensions =
        { pkgs }:
        [
          pkgs.vscode-extensions.jnoortheen.nix-ide
        ];

      outputBuilder =
        args: rawApp:
        let
          app = args.appProcess rawApp;
          name = app.name;
          default = app.default or true;
          pkgsImport = app.pkgsImport or { };
        in
        combine [
          (eachSystem pkgsImport (
            {
              system,
              pkgs,
            }:
            let
              output = args.appBuilder {
                inherit system pkgs app;
              };
            in
            {
              checks.${system}.${name} = output.check;

              packages.${system} = {
                ${name} = output.package;
              }
              // (if default then { default = output.package; } else { });

              devShells.${system} = {
                ${name} = output.devShell;
              }
              // (if default then { default = output.devShell; } else { });

              extras.${system} = { } // (if output ? extra then output.extra else { });
            }
          ))
          (
            let
              enableModule = if app.module or { } ? enable then app.module.enable else true;
              module =
                { pkgs, ... }@nixArgs:
                defaultModule {
                  inherit app nixArgs;
                  builder = args.appBuilder;
                };
            in
            if enableModule then
              {
                nixosModules = {
                  ${name} = module;
                }
                // (if default then { default = module; } else { });
              }
            else
              { }
          )
        ];

      rustApp =
        {
          system,
          pkgs,
          app,
        }:
        let
          name = app.name;
          implementation = app.implementation or "crate2nix";
          getArgs = app.getArgs or ({ pkgs }: { });
          args = getArgs { inherit pkgs; };
          src = app.src or args.src;
          extraCheckArgs = args.extraCheckArgs or args.extraArgs or { };
          extraPackageArgs = args.extraPackageArgs or args.extraArgs or { };
          extraDevShellArgs = args.extraDevShellArgs or args.extraArgs or { };
        in
        (
          if implementation == "crate2nix" then
            let
              build =
                (inputs.crate2nix.tools.${system}.appliedCargoNix {
                  inherit name src;
                }).rootCrate.build;
            in
            {
              check = build.override (
                {
                  runTests = true;
                }
                // extraCheckArgs

              );

              package = build.override extraPackageArgs;
            }
          else if implementation == "naersk" then
            let
              naersk' = pkgs.callPackage inputs.naersk { };
              build = (
                extraArgs:
                naersk'.buildPackage (
                  {
                    inherit name src;
                  }
                  // extraArgs
                )
              );
            in
            {
              check = build ({ mode = "test"; } // extraCheckArgs);

              package = build extraPackageArgs;
            }
          else
            builtins.throw "Unknown implementation ${implementation}"
        )
        // {
          devShell = pkgs.mkShell (
            {
              buildInputs = (defaultDevShellBuildInputs { inherit pkgs; }) ++ [
                pkgs.cargo
                pkgs.rustc
                pkgs.rustfmt
                pkgs.clippy

                (pkgs.vscode-with-extensions.override {
                  vscode = pkgs.vscode;
                  vscodeExtensions = (defaultVsCodeExtensions { inherit pkgs; }) ++ [
                    pkgs.vscode-extensions.rust-lang.rust-analyzer
                    pkgs.vscode-extensions.tamasfe.even-better-toml
                  ];
                })
              ];
              RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
              shellHook = ''
                code .
              '';
            }
            // extraDevShellArgs
          );
        };

      javascriptApp =
        {
          system,
          pkgs,
          app,
        }:
        let
          name = app.name;
          version = app.version;
          getArgs = app.getArgs or ({ pkgs }: { });
          args = getArgs { inherit pkgs; };
          src = app.src or args.src;
          type =
            app.type or (
              if builtins.pathExists (src + "/package-lock.json") then
                "npm"
              else if builtins.pathExists (src + "/yarn.lock") then
                "yarn"
              else if builtins.pathExists (src + "/pnpm-lock.yaml") then
                "pnpm"
              else if builtins.pathExists (src + "/bun.lock") then
                "bun"
              else
                ""
            );
          implementation = app.implementation or "buildNpmPackage";
          framework =
            app.framework or (
              if
                builtins.pathExists (src + "/next.config.js")
                || builtins.pathExists (src + "/next.config.ts")
                || builtins.pathExists (src + "/next.config.mjs")
                || builtins.pathExists (src + "/next.config.cjs")
              then
                "nextjs"
              else if
                builtins.pathExists (src + "/vite.config.js")
                || builtins.pathExists (src + "/vite.config.ts")
                || builtins.pathExists (src + "/vite.config.mjs")
                || builtins.pathExists (src + "/vite.config.cjs")
              then
                "vite"
              else if
                builtins.pathExists (src + "/astro.config.js")
                || builtins.pathExists (src + "/astro.config.ts")
                || builtins.pathExists (src + "/astro.config.mjs")
                || builtins.pathExists (src + "/astro.config.cjs")
              then
                "astro"
              else
                ""
            );
          # extraCheckArgs = args.extraCheckArgs or args.extraArgs or { };
          extraPackageArgs = args.extraPackageArgs or args.extraArgs or { };
          extraDevShellArgs = args.extraDevShellArgs or args.extraArgs or { };
        in
        (
          if implementation == "buildNpmPackage" then
            let
              pname = name;
            in
            {
              # TODO check

              package = pkgs.buildNpmPackage (
                {
                  inherit pname version src;
                }
                // (
                  if type == "npm" then
                    {
                      npmDeps = pkgs.importNpmLock {
                        inherit pname version;
                        npmRoot = src;
                      };
                      npmConfigHook = pkgs.importNpmLock.npmConfigHook;
                    }
                  else
                    { }
                )
                // (
                  let
                    node =
                      if type == "npm" then
                        pkgs.lib.getExe pkgs.nodejs
                      else if type == "yarn" then
                        pkgs.lib.getExe pkgs.yarn
                      else if type == "pnpm" then
                        pkgs.lib.getExe pkgs.pnpm
                      else if type == "bun" then
                        pkgs.lib.getExe pkgs.bun
                      else
                        "";
                    npm =
                      if type == "npm" then
                        "${pkgs.nodejs}/bin/npm"
                      else if type == "yarn" then
                        pkgs.lib.getExe pkgs.yarn
                      else if type == "pnpm" then
                        pkgs.lib.getExe pkgs.pnpm
                      else if type == "bun" then
                        pkgs.lib.getExe pkgs.bun
                      else
                        "";

                    installArgs =
                      (
                        if framework == "nextjs" then
                          {
                            copy = [
                              ".next"
                              "public"
                              "node_modules"
                              "package.json"
                            ];
                            execute = args: "cd ${args.dir} && ${args.npm} run start";
                            commands = ''
                              # https://github.com/vercel/next.js/discussions/58864
                              ln -s /var/cache/${name} $out/share/.next/cache
                            '';
                          }
                        else if framework == "vite" || framework == "astro" then
                          {
                            copy = [ "dist" ];
                            execute = args: "${pkgs.lib.getExe pkgs.static-web-server} --port 3000 --root ${args.dir}/dist";
                          }
                        else if framework == "react" then
                          {
                            copy = [ "build" ];
                            execute = args: "${pkgs.lib.getExe pkgs.static-web-server} --port 3000 --root ${args.dir}/build";
                          }
                        else if framework == "nextjs-standalone" then
                          {
                            copy = [
                              ".next"
                              "public"
                            ];
                            execute = args: "${args.node} ${args.dir}/server.js";
                            commands = ''
                              # https://github.com/vercel/next.js/discussions/58864
                              ln -s /var/cache/${name} $out/share/.next/cache
                              mv $out/share/.next/standalone/* $out/share
                            '';
                          }
                        else if framework == "astro-node" then
                          {
                            copy = [
                              "dist"
                              "node_modules"
                            ];
                            execute = args: "${args.node} ${args.dir}/dist/server/entry.mjs";
                          }
                        else if framework == "astro-node-noext" then
                          {
                            copy = [ "dist" ];
                            execute = args: "${args.node} ${args.dir}/dist/server/entry.mjs";
                          }
                        else
                          { }
                      )
                      // (args.frameworkArgs or { });
                  in
                  {
                    installPhase = ''
                      runHook preInstall

                      mkdir -p $out/{share,bin}
                      ${builtins.concatStringsSep "\n" (
                        builtins.map (toCopy: "cp --parents -r ${toCopy} $out/share") installArgs.copy or [ ]
                      )}
                      cat > $out/bin/${name} << EOF
                      #!${pkgs.lib.getExe pkgs.bash}
                      ${(installArgs.execute or (args: "")) {
                        inherit node npm;
                        dir = "$out/share";
                      }}
                      EOF
                      chmod +x $out/bin/${name}
                      ${installArgs.commands or ""}
                      ${installArgs.extraCommands or ""}

                      runHook postInstall
                    '';
                  }
                )
                // extraPackageArgs
              );
            }
          else
            builtins.throw "Unknown implementation ${implementation}"
        )
        // {
          devShell = pkgs.mkShell (
            {
              buildInputs =
                (defaultDevShellBuildInputs { inherit pkgs; })
                ++ [
                  pkgs.python

                  (pkgs.vscode-with-extensions.override {
                    vscode = pkgs.vscode;
                    vscodeExtensions =
                      (defaultVsCodeExtensions { inherit pkgs; })
                      ++ [
                        pkgs.vscode-extensions.ms-python.python
                      ]
                      ++ (
                        if framework == "vite" then
                          [ pkgs.vscode-extensions.vue.volar ]
                        else if framework == "astro" || framework == "astro-node" then
                          [ pkgs.vscode-extensions.astro-build.astro-vscode ]
                        else
                          [ ]
                      );
                  })
                ]
                ++ (
                  if type == "npm" then
                    [ pkgs.nodejs ]
                  else if type == "yarn" then
                    [ pkgs.yarn ]
                  else if type == "pnpm" then
                    [ pkgs.pnpm ]
                  else if type == "bun" then
                    [ pkgs.bun ]
                  else
                    [ ]
                );
              shellHook = ''
                code .
              '';
            }
            // extraDevShellArgs
          );
        };

      pythonApp =
        {
          system,
          pkgs,
          app,
        }:
        let
          name = app.name;
          version = app.version;
          getArgs = app.getArgs or ({ pkgs }: { });
          args = getArgs { inherit pkgs; };
          src = app.src or args.src;
          type = app.type or (if builtins.pathExists (src + "/uv.lock") then "uv" else "");
          implementation = app.implementation or (if type == "uv" then "uv2nix" else "pyproject.nix");
          # extraCheckArgs = args.extraCheckArgs or args.extraArgs or { };
          extraPackageArgs = args.extraPackageArgs or args.extraArgs or { };
          extraDevShellArgs = args.extraDevShellArgs or args.extraArgs or { };
        in
        (
          if implementation == "pyproject.nix" then
            let
              loader =
                if type == "uv" then
                  "loadUVPyproject"
                else if type == "poetry" then
                  "loadPoetryPyproject"
                else
                  "loadPyproject";
              extraRequirements = args.extraRequirements or [ ];
              python = args.python or pkgs.python3;
              pyproject = pkgs.lib.importTOML (src + (args.pyproject or "/pyproject.toml"));
              baseProject = inputs.pyproject-nix.lib.project.${loader} ({
                inherit pyproject;
                projectRoot = src;
              });
              finalDependencies =
                (builtins.map (
                  requirement:
                  (inputs.pyproject-nix.lib.project.loadRequirementsTxt {
                    requirements =
                      let
                        processRequirements =
                          path:
                          let
                            parentFolder = builtins.dirOf path;
                            rawContent = builtins.readFile path;
                            perLine = pkgs.lib.splitString "\n" rawContent;
                            patchedLines = builtins.map (
                              line:
                              let
                                readFile = pkgs.lib.splitString "-r " line;
                              in
                              if line != "" && builtins.elemAt readFile 0 == "" then
                                processRequirements "${parentFolder}/${builtins.elemAt readFile 1}"
                              else
                                line
                            ) perLine;
                          in
                          builtins.concatStringsSep "\n" patchedLines;
                      in
                      processRequirements (src + "/${requirement}");
                  }).dependencies.dependencies
                ) extraRequirements)
                ++ [ baseProject.dependencies.dependencies ];
              project = baseProject // {
                dependencies = baseProject.dependencies // {
                  dependencies = builtins.concatLists finalDependencies;
                };
              };
            in
            {
              # TODO check

              package = python.pkgs.buildPythonPackage (
                (inputs.pyproject-nix.lib.renderers.buildPythonPackage { inherit python project; })
                // {
                  inherit version;
                  pname = name;
                  pythonRelaxDeps = true;
                }
                // extraPackageArgs
              );
            }
          else if implementation == "uv2nix" then
            let
              workspace = inputs.uv2nix.lib.workspace.loadWorkspace ({ workspaceRoot = src; });
              overlay = workspace.mkPyprojectOverlay {
                sourcePreference = "wheel";
              };
              python = args.python or pkgs.python3;
              pythonSet =
                (pkgs.callPackage inputs.pyproject-nix.build.packages {
                  inherit python;
                }).overrideScope
                  (
                    pkgs.lib.composeManyExtensions ([
                      inputs.pyproject-build-systems.overlays.wheel
                      overlay
                      (extraPackageArgs.override or (final: prev: { }))
                    ])
                  );
              venv =
                (pythonSet.mkVirtualEnv "${name}-${version}-venv" workspace.deps.default).overrideAttrs
                  (old: {
                    venvIgnoreCollisions = [ "*" ];
                  });
            in
            {
              # TODO check

              package = (pkgs.callPackages inputs.pyproject-nix.build.util { }).mkApplication {
                inherit venv;
                package = pythonSet.${name};
              };

              extra = {
                inherit
                  args
                  overlay
                  pythonSet
                  venv
                  ;
              };
            }
          else
            builtins.throw "Unknown implementation ${implementation}"
        )
        // {
          devShell = pkgs.mkShell (
            {
              buildInputs =
                (defaultDevShellBuildInputs { inherit pkgs; })
                ++ [
                  (pkgs.vscode-with-extensions.override {
                    vscode = pkgs.vscode;
                    vscodeExtensions = (defaultVsCodeExtensions { inherit pkgs; }) ++ [
                      pkgs.vscode-extensions.ms-python.python
                    ];
                  })
                ]
                ++ (
                  if type == "uv" then
                    [ pkgs.uv ]
                  else if type == "poetry" then
                    [ pkgs.poetry ]
                  else
                    [ pkgs.python ]
                );
              shellHook = ''
                code .
              '';
            }
            // extraDevShellArgs
          );
        };
    in
    {
      combine = combine;

      language =
        let
          rust = outputBuilder {
            appBuilder = rustApp;
            appProcess =
              app:
              (
                if app ? src then
                  let
                    metadata = builtins.fromTOML (builtins.readFile (app.src + "/Cargo.toml"));
                  in
                  {
                    name = metadata.package.name;
                    version = metadata.package.version;
                  }
                else
                  {
                    name = "rust-app";
                    version = "1.0.0";
                  }
              )
              // app;
          };
          javascript = outputBuilder {
            appBuilder = javascriptApp;
            appProcess =
              app:
              (
                if app ? src then
                  let
                    metadata = builtins.fromJSON (builtins.readFile (app.src + "/package.json"));
                  in
                  {
                    name = metadata.name;
                    version = metadata.version;
                  }
                else
                  {
                    name = "javascript-app";
                    version = "1.0.0";
                  }
              )
              // app;
          };
          python = outputBuilder {
            appBuilder = pythonApp;
            appProcess =
              app:
              (
                if app ? src then
                  let
                    metadata = builtins.fromTOML (builtins.readFile (app.src + "/pyproject.toml"));
                  in
                  {
                    name = metadata.project.name;
                    version = metadata.project.version;
                  }
                else
                  {
                    name = "python-app";
                    version = "1.0.0";
                  }
              )
              // app;
          };
        in
        {
          inherit rust javascript python;

          auto =
            app:
            if builtins.pathExists (app.src + "/Cargo.toml") then
              rust app
            else if builtins.pathExists (app.src + "/package.json") then
              javascript app
            else if builtins.pathExists (app.src + "/pyproject.toml") then
              python app
            else
              builtins.throw "Could not detect language";
        };

      templates = {
        rust = {
          path = ./templates/rust/hello-world;
        };
        uv = {
          path = ./templates/python/uv;
        };
        nodejs = {
          path = ./templates/javascript/nodejs;
        };
        nextjs = {
          path = ./templates/javascript/nextjs;
        };
        vite = {
          path = ./templates/javascript/vite;
        };
        astro = {
          path = ./templates/javascript/astro;
        };
        react = {
          path = ./templates/javascript/react;
        };
      };
    };
}
