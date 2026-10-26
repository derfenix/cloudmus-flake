{
  description = "CloudMus — a multi-source music player, built from source (Qt6 frontend + Python backends)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      version = "0.6.4";

      # Upstream tags releases without a leading "v" (0.6.2, not v0.6.2) and
      # ships no submodules (.gitmodules does not exist in the repo), so a
      # plain fetchFromGitHub of the tag is the whole source.
      src = pkgs.fetchFromGitHub {
        owner = "cloudmus";
        repo = "cloudmus";
        tag = version;
        hash = "sha256-aBmYwnExmzR3e4TU5saIVhU+djgSr1mDUbi7nAg51hE=";
      };

      # --- Generated protocol code ------------------------------------------
      # protocol/codegen/generate.py renders both language bindings from
      # protocol/schema/*.yaml + methods.yaml. CMake regenerates the C++ ones
      # itself into fronts/qt/generated/, but the Python ones land in
      # backends/py-rpc-common/rpc_common/generated/ and are imported by
      # rpc_common and by every backend, so they must exist before that
      # package is built. Both output directories are gitignored upstream:
      # there is no pregenerated copy in the tarball.
      codegen = pkgs.python3.withPackages (ps: [
        ps.jinja2
        ps.pyyaml
      ]);

      pythonStubs = pkgs.runCommand "cloudmus-python-protocol-stubs" { nativeBuildInputs = [ codegen ]; } ''
        cp -r ${src} repo
        # The store copy is read-only, codegen writes next to the sources.
        chmod -R u+w repo
        cd repo
        python protocol/codegen/generate.py --lang python
        mkdir -p $out
        cp -r backends/py-rpc-common/rpc_common/generated $out/
      '';

      # --- Python backends --------------------------------------------------
      # Upstream pip-installs these four distributions into a bundled CPython
      # inside the AppImage (packaging/appimage/build-in-docker.sh, step 3);
      # here they are ordinary packages of the flake's own interpreter. The
      # front spawns them by the absolute interpreter path from their manifest.
      python = pkgs.python3;

      rpcCommon = python.pkgs.buildPythonPackage {
        pname = "cloudmus-rpc-common";
        version = "0.1.0";
        pyproject = true;
        src = "${src}/backends/py-rpc-common";
        build-system = [ python.pkgs.setuptools ];
        dependencies = with python.pkgs; [
          jsonschema
          pyyaml
        ];
        postPatch = ''
          cp -r ${pythonStubs}/generated rpc_common/generated
        '';
        doCheck = false;
      };

      # The PyPI library the Yandex Music backend is built on. nixpkgs does
      # not package it (no python3Packages.yandex-music), so it is built here.
      #
      # 3.2.2 — версия, которая лежала в AppImage upstream в тот момент, когда мы
      # её выбирали (сверяли с их релизом 0.6.2, usr/python-runtime/lib/python3.11/
      # site-packages/yandex_music-3.2.2.dist-info); бэкенд просит >=3.0.0.
      # Сам по себе этот пин не устаревает, но сверка — историческая: обновляя
      # его, посмотрите, что лежит в их AppImage сейчас.
      #
      # The dependency list below is not guessed: it is what the published
      # metadata of that release declares (PEP 658, fetched from
      # .../yandex_music-3.2.2-py3-none-any.whl.metadata):
      #   Requires-Python: >=3.8
      #   Requires-Dist: requests[socks]
      #   Requires-Dist: typing-extensions>=4.4.0
      # Its extras (async/crypto/orjson/ujson/pydantic-core/ynison) are not
      # needed: the backend imports only the sync Client,
      # yandex_music.utils.request.Request and yandex_music.exceptions, and
      # nothing from aiohttp/aiofiles/cryptography/ujson/betterproto/websockets.
      yandexMusic = python.pkgs.buildPythonPackage rec {
        pname = "yandex-music";
        version = "3.2.2";
        # Пин меняется руками, не workflow из .github/workflows/update.yml:
        # между версиями у библиотеки меняются зависимости и extras, и ошибиться
        # тут дороже, чем обновить CloudMus. Сверяйтесь с метаданными релиза.
        pyproject = true;
        # fetchPypi builds its URL from pname, and PyPI's source shorthand only
        # exists in the underscored form (packages/source/y/yandex_music/
        # yandex_music-3.2.2.tar.gz is the real file; the dashed form 404s).
        src = pkgs.fetchPypi {
          pname = "yandex_music";
          inherit version;
          hash = "sha256-6wtCQFIc4tBP/4dsna2n7OZUWTeZe6Eg/PqoE++CVrI=";
        };
        # pyproject.toml: requires = ["hatchling>=1.27"], backend hatchling.build
        build-system = [ python.pkgs.hatchling ];
        dependencies = with python.pkgs; [
          requests
          pysocks # the "socks" extra of requests
          typing-extensions
        ];
        # The sdist ships its own suite (255 test files); it runs offline and
        # passes in the sandbox: 2367 passed, 59 skipped. The skips are the
        # suite's own gates for the optional extras deliberately not installed
        # (orjson/ujson/pydantic_core/betterproto), not failures.
        # pytestCheckHook brings pytest.
        nativeCheckInputs = [ python.pkgs.pytestCheckHook ];
      };

      backendLocalFolder = python.pkgs.buildPythonPackage {
        pname = "cloudmus-backend-local-folder";
        version = "0.1.0";
        pyproject = true;
        src = "${src}/backends/local-folder";
        build-system = [ python.pkgs.setuptools ];
        dependencies = [
          rpcCommon
          python.pkgs.mutagen
        ];
        doCheck = false;
      };

      backendYoutubeMusic = python.pkgs.buildPythonPackage {
        pname = "cloudmus-backend-youtube-music";
        version = "0.1.0";
        pyproject = true;
        src = "${src}/backends/youtube-music";
        build-system = [ python.pkgs.setuptools ];
        dependencies = [
          rpcCommon
          python.pkgs.pysocks # SOCKS proxies (ALL_PROXY), see docs/protocol.md §4.3
          python.pkgs.ytmusicapi
          # pyproject.toml pins yt-dlp==2026.9.27.232945.dev0 — a pre-release,
          # "bumped by hand when YouTube breaks stream extraction". nixpkgs has
          # no such version (it ships 2026.08.19), and pinning a PyPI
          # pre-release would need a hand-written derivation; the nixpkgs
          # release build of the same tool is used instead.
          python.pkgs.yt-dlp
        ];
        # The wheel's own metadata keeps that exact pin, which the
        # runtime-dependency check then rejects: relax the specifier so the
        # nixpkgs yt-dlp above is accepted (a recorded, deliberate divergence,
        # not a removed dependency).
        pythonRelaxDeps = [ "yt-dlp" ];
        doCheck = false;
      };

      backendYandexMusic = python.pkgs.buildPythonPackage {
        pname = "cloudmus-backend-yandex-music";
        version = "0.1.0";
        pyproject = true;
        src = "${src}/backends/yandex-music";
        build-system = [ python.pkgs.setuptools ];
        dependencies = [
          rpcCommon
          yandexMusic
          python.pkgs.pysocks # SOCKS proxies, as in the backend's own pyproject
        ];
        # Its 84 tests run offline and pass in the sandbox; pytest-asyncio for
        # the @pytest.mark.asyncio ones.
        nativeCheckInputs = [
          python.pkgs.pytestCheckHook
          python.pkgs.pytest-asyncio
        ];
      };

      # All three sources the upstream AppImage ships.
      backendPython = python.withPackages (_: [
        rpcCommon
        backendLocalFolder
        backendYandexMusic
        backendYoutubeMusic
      ]);

      # Backend manifests. The front reads installed backends only from
      # $XDG_CONFIG_HOME/cloudmus/backends.d/*.json (src/Rpc/BackendManifest.cpp,
      # discoverManifests) — its other discovery paths are Windows-only or a
      # dev-mode repo checkout. Upstream's AppRun writes the AppImage's
      # manifests there on every launch for exactly this reason; this does the
      # same, and like AppRun it writes only its own three files, so a manifest
      # a user put there for their own backend stays untouched.
      #
      # $1 is the package's own $out (an AppImage has a fresh mount point every
      # launch, so AppRun cannot embed these paths; a store path is stable, but
      # the script is still run every launch — it is idempotent).
      seedBackends = pkgs.writeShellScript "cloudmus-seed-backends" ''
        out="$1"

        # A broken manifest directory must not stop the app from starting:
        # upstream's AppRun warns and goes on, this exits 0 and goes on.
        configHome="''${XDG_CONFIG_HOME:-''${HOME:-/nonexistent}/.config}"
        # XDG_CONFIG_HOME counts only when absolute, like QStandardPaths.
        case "$configHome" in
          /*) ;;
          *) configHome="''${HOME:-/nonexistent}/.config" ;;
        esac
        dir="$configHome/cloudmus/backends.d"
        mkdir -p "$dir" 2>/dev/null || exit 0

        # argv[0] is an absolute path on purpose: the front passes its own
        # environment to the backends, so a bare python3 would be the user's
        # (which does not have these packages) — see BackendManifest.cpp.
        write_manifest() {
          id="$1"
          name="$2"
          module="$3"
          protocol="$4"
          cat > "$dir/$id.json" <<JSON || exit 0
        {"id":"$id","name":"$name","argv":["${backendPython}/bin/python3","-m","$module"],"protocolVersion":"$protocol","icon":"$out/share/cloudmus/backend-icons/$id.svg"}
        JSON
        }

        # protocolVersion is the value from each backend's own manifest.json
        # in the repo (local-folder 1.12, the other two 1.8), not the constant
        # 1.2 AppRun writes for all of them.
        write_manifest local-folder "Local Folder" cloudmus_backend_local 1.12
        write_manifest yandex-music "Yandex Music" cloudmus_backend_yandex 1.8
        write_manifest youtube-music "YouTube Music" cloudmus_backend_ytmusic 1.8
      '';

      cloudmus = pkgs.stdenv.mkDerivation {
        pname = "cloudmus";
        inherit version src;

        nativeBuildInputs = [
          pkgs.cmake # fronts/qt/CMakeLists.txt requires >= 3.21
          pkgs.ninja
          pkgs.pkg-config # find_package(PkgConfig) for libmpv
          pkgs.qt6.qttools # Qt6::LinguistTools (lupdate/lrelease), a build-time tool
          pkgs.qt6.wrapQtAppsHook
          pkgs.clang-tools # clang-format: protocol/codegen/generate.py formats the
                           # generated C++ with it and warns when it is missing
          pkgs.wayland-scanner # the blur protocols, wayland-scanner client-header/private-code
          codegen # CMake's protocol codegen step
        ];

        buildInputs = [
          pkgs.qt6.qtbase # Core Gui Widgets Network DBus (find_package(Qt6 COMPONENTS ...))
          pkgs.qt6.qtsvg # Qt6::Svg
          # The Wayland *platform* plugin (platforms/libqwayland.so, next to
          # libqxcb.so) comes from qtbase in this nixpkgs release; qtwayland
          # adds its shell/decoration/graphics-integration plugins
          # (wayland-shell-integration, wayland-decoration-client,
          # wayland-graphics-integration-server) — the client-side decoration
          # plugin among them, which a compositor that does no server-side
          # decorations needs.
          pkgs.qt6.qtwayland
          pkgs.mpv-unwrapped # libmpv via pkg-config (pkg_check_modules(MPV REQUIRED ...))
          pkgs.taglib # find_package(TagLib 2.2 CONFIG) — 2.2.1 here, so no FetchContent
          pkgs.wayland # wayland-client for the blur protocols
          pkgs.libxcb # xcb: KWin's X11 blur property + X11 global hotkeys
        ];

        # The CMake project is fronts/qt, there is no CMakeLists at the repo
        # root. The cmake hook configures from a "build" subdirectory, so this
        # is relative to that.
        cmakeDir = "../fronts/qt";
        cmakeBuildType = "Release";
        cmakeFlags = [
          # Beats the hook's own PATH lookup: generate.py needs jinja2+pyyaml.
          "-DPYTHON3_EXECUTABLE=${codegen}/bin/python3"
          # cmake/Version.cmake gets CLOUDMUS_VERSION from `git describe`, which
          # a fetchFromGitHub tarball has no metadata for: without this the app
          # (About dialog, and the update checker comparing against the release
          # feed) would call itself 0.1.0, the base version in project().
          "-DCLOUDMUS_VERSION_OVERRIDE=${version}"
        ];

        # The project declares no install() rules at all, so (with CMake 4)
        # there is no "install" target and `ninja install` fails outright.
        # Everything is installed from postInstall below instead.
        dontUseNinjaInstall = true;

        # Sentry crash reporting is deliberately not enabled: without a DSN
        # it defaults to OFF upstream (CMakeLists.txt CLOUDMUS_SENTRY) and
        # builds its own sentry-native via FetchContent, which needs network
        # in a sandboxed build. Google Analytics is absent for the same reason
        # (CLOUDMUS_GA4_MEASUREMENT_ID is a release-build secret). CLOUDMUS_TLS_CA_FILE
        # is not set either: it exists because the AppImage's bundled
        # libavformat trusts Debian's CA path, while the nixpkgs one uses the
        # host's /etc/ssl/certs/ca-certificates.crt.

        # Upstream wraps its own AppRun around the app for exactly one reason
        # left here (the other AppRun steps are AppImage-specific): the backend
        # manifests, see postInstall. wrapQtAppsHook does the Qt part on its
        # own — the plugin path, so the xcb/wayland platform plugins are found.

        postInstall = ''
          # fronts/qt/CMakeLists.txt declares no install() rules (upstream's
          # AppImage copies the binary straight out of the build tree), so the
          # binary and the desktop integration are installed here. The cwd of
          # this phase is the cmake build directory, where the CMakeLists'
          # CMAKE_RUNTIME_OUTPUT_DIRECTORY puts the executable.
          install -Dm755 bin/cloudmus-qt $out/bin/cloudmus-qt

          # Launcher: seeds the backend manifests, then starts the app.
          # Upstream's AppRun does the same before the app starts, for the same
          # reason — the front finds installed backends only through a manifest
          # in $XDG_CONFIG_HOME/cloudmus/backends.d (src/Rpc/BackendManifest.cpp).
          # It is a separate executable rather than makeWrapper's --run because
          # this nixpkgs' makeWrapper is the binary one, which has no --run;
          # cloudmus-qt is wrapped by wrapQtAppsHook as usual.
          # The delimiter is quoted so the build shell leaves "$@" alone
          # (the Nix-level paths are already substituted above).
          cat > $out/bin/cloudmus <<'EOF'
          #!/bin/sh
          # A failed step here must not keep the app from starting.
          ${seedBackends} ${placeholder "out"} || true
          exec ${placeholder "out"}/bin/cloudmus-qt "$@"
          EOF
          chmod 755 $out/bin/cloudmus

          # Same desktop entry as packaging/appimage/build-in-docker.sh installs
          # into the AppDir, with its Exec= pointing at the launcher — exactly
          # what AppRun's own desktop_entry() does for the AppImage.
          mkdir -p $out/share/applications
          sed 's|^Exec=.*|Exec=cloudmus|' ${src}/packaging/appimage/cloudmus-qt.desktop \
            > $out/share/applications/cloudmus-qt.desktop

          # The window/tray icon, looked up by the app id "cloudmus-qt".
          install -Dm644 ${src}/art/logo.png \
            $out/share/icons/hicolor/512x512/apps/cloudmus-qt.png

          # Each backend's sidebar icon, referenced by the manifests above.
          for id in local-folder yandex-music youtube-music; do
            install -Dm644 ${src}/backends/$id/icon.svg \
              $out/share/cloudmus/backend-icons/$id.svg
          done
        '';

        meta = {
          description = "Multi-source music player (Yandex Music, YouTube Music, local files)";
          homepage = "https://cloudmus.app";
          license = lib.licenses.mit;
          mainProgram = "cloudmus";
          platforms = [ "x86_64-linux" ];
        };
      };
    in
    {
      packages.${system} = {
        default = cloudmus;
        cloudmus = cloudmus;
      };

      devShells.${system}.default = pkgs.mkShell {
        inputsFrom = [ cloudmus ];
        packages = [ codegen ];
        shellHook = ''
          echo "CloudMus ${version} dev shell."
          echo "Configure with: cmake -S fronts/qt -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DPYTHON3_EXECUTABLE=$(command -v python3)"
        '';
      };
    };
}
