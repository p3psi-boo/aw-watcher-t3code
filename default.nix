{
  lib,
  stdenv,
  zig_0_17,
}:

stdenv.mkDerivation {
  pname = "aw-watcher-t3code";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  nativeBuildInputs = [ zig_0_17 ];
  dontConfigure = true;
  doCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  __darwinAllowLocalNetworking = true;

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
  '';
  buildPhase = ''
    runHook preBuild
    zig build -Doptimize=ReleaseFast ${lib.optionalString stdenv.hostPlatform.isLinux "-Dtarget=${stdenv.hostPlatform.parsed.cpu.name}-linux-musl"}
    runHook postBuild
  '';
  checkPhase = ''
    runHook preCheck
    zig build test
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 zig-out/bin/aw-watcher-t3code "$out/bin/aw-watcher-t3code"
    runHook postInstall
  '';

  meta = {
    description = "Read-only T3 Code activity watcher for ActivityWatch";
    mainProgram = "aw-watcher-t3code";
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
