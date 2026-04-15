{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  pkg-config,
  cmake,
  bun,
  nodejs,
  cctools,
  cargo-tauri,
  jq,
  nix-update-script,
  writableTmpDirAsHomeHook,
  makeBinaryWrapper,
  swift,

  # Linux-only
  webkitgtk_4_1,
  gtk3,
  glib,
  libsoup_3,
  alsa-lib,
  libayatana-appindicator,
  libevdev,
  libxtst,
  gtk-layer-shell,
  vulkan-loader,
  vulkan-headers,
  shaderc,
  gst_all_1,
  glib-networking,
  libx11,
  pipewire,
  alsa-plugins,
  symlinkJoin,
  wrapGAppsHook4,

  # Cross-platform
  onnxruntime,
  openssl,
}:

rustPlatform.buildRustPackage (
  finalAttrs:
  let
    gstPlugins = lib.optionals stdenv.hostPlatform.isLinux (
      with gst_all_1;
      [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
        gst-plugins-ugly
      ]
    );

    # Bun node_modules as a fixed-output derivation; --production is intentionally
    # omitted because devDeps (e.g. @types/*) are required for `tsc` at build time.
    #
    # Bun's isolated install is not bit-reproducible on its own: symlink
    # creation order in .bun/node_modules/ and in each package's .bin/
    # directory is not stable, and a timing race in the installer drops
    # some `.bin/<peer>` entries around circular peer dependencies. Handy
    # ships a tiny post-install orchestrator at
    # `.nix/scripts/normalize-install.ts` that runs three passes
    # (canonicalize → heal → normalize) to produce a stable, idempotent
    # node_modules/ tree; see that file's header for the full story. We
    # call it here unconditionally right after `bun install`.
    #
    # Even with the tree stable within a platform, bun still downloads
    # only the host-matching native binaries (esbuild, rollup, tauri-cli,
    # lightningcss, tailwindcss-oxide, ...), so the hash differs between
    # Linux and darwin. We store one hash per system; platforms without
    # a known hash `throw` rather than fall back, so a drive-by build on
    # an unsupported system fails fast with a pointer at the update
    # script (see `passthru.updateScript`).
    #
    # TODO: switch to bun.fetchDeps once NixOS/nixpkgs#376299 is merged.
    frontendDepsHashes = {
      "x86_64-linux" = "sha256-tJ6LK99dELOiR0BcsTRTt/vLyNamntujLxhBy5Xl/lc=";
      "aarch64-linux" = "sha256-S+dX6ZVgv9dexxIHoa5PxP7e0nxf/d7cKUGty5eEi8A=";
      "aarch64-darwin" = "sha256-DQbogNBQ9izK5GPmoOudqiB2lJvct1vZI2U5lp3WFy8=";
    };
    frontendDeps = stdenv.mkDerivation {
      pname = "${finalAttrs.pname}-frontend-deps";
      inherit (finalAttrs) version src;
      nativeBuildInputs = [
        bun
        writableTmpDirAsHomeHook
      ];
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
        bun install --linker=isolated --force --frozen-lockfile \
          --ignore-scripts --no-progress
        bun --bun "$PWD/.nix/scripts/normalize-install.ts"
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -R node_modules $out/
        runHook postInstall
      '';
      dontFixup = true;
      outputHash =
        frontendDepsHashes.${stdenv.hostPlatform.system} or (throw ''
          handy: no frontendDeps hash for ${stdenv.hostPlatform.system}.
          Run `nix-update --flake handy` (or the equivalent `passthru.updateScript`)
          on a host of that system and paste the value into
          pkgs/by-name/ha/handy/package.nix:frontendDepsHashes.
        '');
      outputHashMode = "recursive";
    };
  in
  {
    pname = "handy";
    version = "0.8.2";

    __structuredAttrs = true;

    # TEMPORARY: pin src to the HEAD of cjpais/Handy#1256 so the post-install
    # orchestrator (`.nix/scripts/normalize-install.ts`) is present in the
    # source tree while that PR is still open. GitHub exposes PR commits on
    # the base repository, so we can fetch it via `owner = "cjpais"` without
    # indirecting through a fork. Revert to `tag = "v${finalAttrs.version}";`
    # once #1256 merges and a Handy release containing the scripts is cut.
    src = fetchFromGitHub {
      owner = "cjpais";
      repo = "Handy";
      rev = "681c6a991b7e55bd04ef9963aeb45767ebacba2e";
      hash = "sha256-9SfVRef31Ak4H4yEUmw0R8ySqWV9F98LUhSCH+rGw/I=";
    };

    cargoRoot = "src-tauri";
    cargoHash = "sha256-qwcKuPfSLVmjIkduKkIRCmVk6BPbxF5htfY6f+6yV0w=";

    postPatch = ''
      # Strip updater artifacts; disable macOS code-signing (no identity in sandbox)
      ${jq}/bin/jq '
        del(.build.beforeBuildCommand) |
        .bundle.createUpdaterArtifacts = false |
        .bundle.macOS.signingIdentity = null |
        .bundle.macOS.hardenedRuntime = false
      ' src-tauri/tauri.conf.json > $TMPDIR/tauri.conf.json
      cp $TMPDIR/tauri.conf.json src-tauri/tauri.conf.json

      ${jq}/bin/jq 'del(.scripts.postinstall)' package.json > $TMPDIR/package.json
      cp $TMPDIR/package.json package.json

      # cbindgen calls `cargo metadata` which fails in the Nix sandbox.
      find $cargoDepsCopy -path "*/ferrous-opencc-*/build.rs" \
        -exec sed -i \
          -e '/cbindgen::Builder::new/{:l;/write_to_file/!{N;bl};d}' \
          {} \;
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      find $cargoDepsCopy -path "*/libappindicator-sys-*/src/lib.rs" \
        -exec sed -i \
          's|libayatana-appindicator3.so.1|${libayatana-appindicator}/lib/libayatana-appindicator3.so.1|' \
          {} \;
    ''
    + lib.optionalString stdenv.hostPlatform.isDarwin ''
      patch -p1 < ${./use-nix-swift.patch}
    '';

    nativeBuildInputs = [
      pkg-config
      cmake
      bun
      nodejs
      cargo-tauri.hook
      jq
      rustPlatform.bindgenHook
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      wrapGAppsHook4
      shaderc
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      makeBinaryWrapper
      cctools
      swift
    ];

    buildInputs = [
      onnxruntime
      openssl
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      webkitgtk_4_1
      gtk3
      glib
      libsoup_3
      alsa-lib
      libayatana-appindicator
      libevdev
      libxtst
      gtk-layer-shell
      vulkan-loader
      vulkan-headers
      glib-networking
      libx11
    ]
    ++ gstPlugins;

    env = {
      ORT_LIB_LOCATION = "${onnxruntime}/lib";
      ORT_PREFER_DYNAMIC_LINK = "1";
      GST_PLUGIN_SYSTEM_PATH_1_0 = lib.optionalString stdenv.hostPlatform.isLinux (
        lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" gstPlugins
      );
      OPENSSL_NO_VENDOR = "1";
    }
    // lib.optionalAttrs stdenv.hostPlatform.isDarwin {
      SWIFTC = "${swift}/bin/swiftc";
    };

    preBuild = ''
      cp -R ${frontendDeps}/node_modules .
      chmod -R u+w node_modules
      patchShebangs node_modules
      export HOME=$TMPDIR
      bun run build
    '';

    doCheck = false;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      mv src-tauri/target/${stdenv.hostPlatform.rust.rustcTarget}/release/bundle/deb/*/data/usr/* $out/
    ''
    + lib.optionalString stdenv.hostPlatform.isDarwin ''
      mkdir -p $out/Applications $out/bin
      mv src-tauri/target/${stdenv.hostPlatform.rust.rustcTarget}/release/bundle/macos/Handy.app \
        $out/Applications/
      makeWrapper "$out/Applications/Handy.app/Contents/MacOS/handy" "$out/bin/handy"
    ''
    + ''
      runHook postInstall
    '';

    preFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
      gappsWrapperArgs+=(
        --set WEBKIT_DISABLE_DMABUF_RENDERER 1
        --set ALSA_PLUGIN_DIR "${
          symlinkJoin {
            name = "combined-alsa-plugins";
            paths = [
              "${pipewire}/lib/alsa-lib"
              "${alsa-plugins}/lib/alsa-lib"
            ];
          }
        }"
        --prefix LD_LIBRARY_PATH : "${
          lib.makeLibraryPath [
            vulkan-loader
            onnxruntime
          ]
        }"
      )
    '';

    # Bake the onnxruntime dylib path into the binary's rpath so it can be found
    # at runtime without relying on the infamous DYLD_LIBRARY_PATH (blocked by SIP on macOS).
    postFixup = lib.optionalString stdenv.hostPlatform.isDarwin ''
      install_name_tool -add_rpath ${onnxruntime}/lib \
        "$out/Applications/Handy.app/Contents/MacOS/handy"
    '';

    passthru = {
      # Expose frontendDeps so it can be built directly by the update
      # script (or by hand) without dragging in the full handy compile.
      inherit frontendDeps;

      # nix-update refreshes version + src + cargoHash on its own; the
      # `--subpackage frontendDeps` flag tells it to also rebuild
      # `handy.passthru.frontendDeps` and replace the entry in
      # `frontendDepsHashes` matching the current host's system. Each
      # target system needs a separate run on the appropriate host.
      updateScript = nix-update-script {
        extraArgs = [
          "--subpackage"
          "frontendDeps"
        ];
      };
    };

    meta = {
      description = "Free, open source, offline speech-to-text application";
      longDescription = ''
        Handy is a cross-platform desktop application providing simple,
        privacy-focused speech transcription. Press a shortcut, speak, and
        have your words appear in any text field — entirely on your own
        computer, with no audio sent to the cloud.
      '';
      homepage = "https://handy.computer";
      changelog = "https://github.com/cjpais/Handy/releases/tag/v${finalAttrs.version}";
      license = lib.licenses.mit;
      mainProgram = "handy";
      maintainers = with lib.maintainers; [ philocalyst ];
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
)
