{
  lib,
  rustPlatform,
  fetchFromGitHub,
  u-config,
  installShellFiles,
  sqlite,
  zlib,
  versionCheckHook,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "syntaqlite";
  version = "0.2.15";

  src = fetchFromGitHub {
    owner = "LalitMaganti";
    repo = "syntaqlite";
    tag = "v${finalAttrs.version}";
    hash = "sha256-VZqnvTd09mmiUBuzWJ7Rj93TqeO73Op+Tu3g+q5uuLA=";
  };

  cargoHash = "sha256-9IVI2Bxp9rYeIGNhx5MhYSbLMIXO4ZnwhM2R41vugHs=";

  # CLI contains MCP and LSP
  buildAndTestSubdir = "syntaqlite-cli";

  nativeBuildInputs = [
    u-config
    installShellFiles
  ];

  buildInputs = [
    sqlite
    zlib
  ];

  buildFeatures = [ "default" ];

  # Some integration tests require a live SQLite database or network access
  checkFlags = [
    "--skip=integration"
  ];

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  meta = {
    description = "Fast, accurate SQLite SQL formatter, validator, and language server — built on SQLite's own grammar";
    homepage = "https://syntaqlite.com";
    changelog = "https://github.com/LalitMaganti/syntaqlite/blob/v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.asl20;
    mainProgram = "syntaqlite";
    maintainers = with lib.maintainers; [ philocalyst ];
  };
})
