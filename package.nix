# Claude Code Package
#
# This package installs the native Claude Code binary from Anthropic.

{ lib
, stdenv
, fetchurl
, bash
, patchelf
, jq
}:

let
  version = "2.1.33";

  # Platform mapping for native binaries (Nix system -> Anthropic platform)
  platformMap = {
    "aarch64-darwin" = "darwin-arm64";
    "x86_64-darwin" = "darwin-x64";
    "x86_64-linux" = "linux-x64";
    "aarch64-linux" = "linux-arm64";
  };

  platform = platformMap.${stdenv.hostPlatform.system} or null;

  # Native binary hashes per platform
  nativeHashes = {
    "darwin-arm64" = "1p9f84gysi2vmzm1if7dk5qbnbaahzv1bn5p1ak4pacrg1ss0rs1";
    "darwin-x64" = "065flaz9xnc7hbp50y9a6gr22089y8bjjbiynn3wfm08swm026g8";
    "linux-x64" = "0p43v0phr54p1wjaa7dz903qaw2944nbm9ra037n7sazycqmjrf8";
    "linux-arm64" = "16q5b7vgqi625qzig51y9db682ryy8c9ivq41z85a21ff3k2gxky";
  };

  # Native binary URL
  nativeBinaryUrl = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}/${platform}/claude";

  # Fetch native binary
  nativeBinary = fetchurl {
    url = nativeBinaryUrl;
    sha256 = nativeHashes.${platform};
  };
in
assert platform != null ||
  throw "Native runtime not supported on ${stdenv.hostPlatform.system}. Supported: aarch64-darwin, x86_64-darwin, x86_64-linux, aarch64-linux";

stdenv.mkDerivation rec {
  pname = "claude-code";
  inherit version;

  dontUnpack = true;

  # For native runtime: disable automatic patching/stripping which corrupts the Bun trailer
  dontPatchELF = true;
  dontStrip = true;

  nativeBuildInputs = lib.optionals stdenv.isLinux [ patchelf ];
  buildInputs = [];

  buildPhase = ''
    runHook preBuild
    mkdir -p build
    cp ${nativeBinary} build/.claude-unwrapped
    chmod u+w,+x build/.claude-unwrapped

    ${lib.optionalString stdenv.isLinux ''
    # Patch only the interpreter for NixOS compatibility
    # Do NOT use --set-rpath as it corrupts the Bun embedded payload
    patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" build/.claude-unwrapped

    # Verify the Bun trailer is still intact
    if ! tail -c 20 build/.claude-unwrapped | grep -q "Bun!"; then
      echo "ERROR: Bun trailer was corrupted by patchelf!"
      exit 1
    fi
    ''}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin

    # Install the patched binary as a hidden unwrapped name
    cp build/.claude-unwrapped $out/bin/.claude-unwrapped
    chmod +x $out/bin/.claude-unwrapped

    # Create claude-raw wrapper that intercepts --model flag and applies env injection.
    # Claude Code spawns claude-raw for sub-agents, so interception must happen here.
    cat > $out/bin/claude-raw << 'EOF'
#!@bash@/bin/bash
set -o pipefail

CLAUDE_UNWRAPPED="@out@/bin/.claude-unwrapped"
export CLAUDE_EXECUTABLE_PATH="$HOME/.local/bin/claude"
export DISABLE_AUTOUPDATER=1
export DISABLE_INSTALLATION_CHECKS=1

# Extract --model from arguments and strip it
MODEL=""
FILTERED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --model=*)
            MODEL=''${1#--model=}
            shift
            ;;
        *)
            FILTERED_ARGS+=("$1")
            shift
            ;;
    esac
done

# Apply model-based environment if a model was specified
if [[ -n "$MODEL" ]]; then
    JQ="@jq@/bin/jq"
    MAPPING_FILE=""

    if [[ -f "model-mapping.json" ]]; then
        MAPPING_FILE="$(pwd)/model-mapping.json"
    elif [[ -f "$HOME/.claude/model-mapping.json" ]]; then
        MAPPING_FILE="$HOME/.claude/model-mapping.json"
    fi

    if [[ -n "$MAPPING_FILE" ]] && "$JQ" -e ".\"$MODEL\"" "$MAPPING_FILE" >/dev/null 2>&1; then
        while IFS='=' read -r key value; do
            [[ -n "$key" ]] && eval "export $key=\"$value\""
        done < <("$JQ" -r ".\"$MODEL\" | to_entries | .[] | \"\(.key)=\(.value)\"" "$MAPPING_FILE" 2>/dev/null)
    fi
fi

exec "$CLAUDE_UNWRAPPED" "''${FILTERED_ARGS[@]}"
EOF
    chmod +x $out/bin/claude-raw
    substituteInPlace $out/bin/claude-raw \
        --replace-fail '@bash@' '${bash}' \
        --replace-fail '@out@' "$out" \
        --replace-fail '@jq@' '${jq}'

    # claude is a symlink to claude-raw (same --model handling)
    ln -s claude-raw $out/bin/claude
    runHook postInstall
  '';

  meta = with lib; {
    description = "Claude Code (Native Binary) - AI coding assistant in your terminal";
    homepage = "https://www.anthropic.com/claude-code";
    license = licenses.unfree;
    platforms = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
    mainProgram = "claude";
  };
}
