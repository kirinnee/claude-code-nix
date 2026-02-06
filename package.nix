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
    cp ${nativeBinary} build/claude-raw
    chmod u+w,+x build/claude-raw

    ${lib.optionalString stdenv.isLinux ''
    # Patch only the interpreter for NixOS compatibility
    # Do NOT use --set-rpath as it corrupts the Bun embedded payload
    patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" build/claude-raw

    # Verify the Bun trailer is still intact
    if ! tail -c 20 build/claude-raw | grep -q "Bun!"; then
      echo "ERROR: Bun trailer was corrupted by patchelf!"
      exit 1
    fi
    ''}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin

    # Install the patched binary
    cp build/claude-raw $out/bin/claude-raw
    chmod +x $out/bin/claude-raw

    # Create wrapper script with model-based env var mapping
    cat > $out/bin/claude << 'EOF'
#!@bash@/bin/bash
set -o pipefail

# Path to the raw binary
CLAUDE_RAW="@out@/bin/claude-raw"
export CLAUDE_EXECUTABLE_PATH="$HOME/.local/bin/claude"
export DISABLE_AUTOUPDATER=1
export DISABLE_INSTALLATION_CHECKS=1

# Extract model from arguments, building filtered args list
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

# Function to load and apply model environment mapping
apply_model_env() {
    local model="$1"
    local mapping_file=""
    local jq="@jq@/bin/jq"

    # Check current directory first, then home directory
    if [[ -f "model-mapping.json" ]]; then
        mapping_file="$(pwd)/model-mapping.json"
    elif [[ -f "$HOME/.claude/model-mapping.json" ]]; then
        mapping_file="$HOME/.claude/model-mapping.json"
    else
        return 0
    fi

    # Check if model exists in mapping
    if ! "$jq" -e ".\"$model\"" "$mapping_file" >/dev/null 2>&1; then
        return 0
    fi

    # Extract env vars for the model
    local env_vars
    env_vars=$("$jq" -r ".\"$model\" | to_entries | .[] | \"\(.key)=\(.value)\"" "$mapping_file" 2>/dev/null) || return 0

    # Export each env var with expansion (properly quoted)
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] && eval "export $key=\"$value\""
    done <<< "$env_vars"
}

# Apply model-based environment if model was specified
if [[ -n "$MODEL" ]]; then
    apply_model_env "$MODEL"
fi

# Execute the raw binary with filtered arguments (without --model)
exec "$CLAUDE_RAW" "''${FILTERED_ARGS[@]}"
EOF
    chmod +x $out/bin/claude
    substituteInPlace $out/bin/claude \
        --replace-fail '@bash@' '${bash}' \
        --replace-fail '@out@' "$out" \
        --replace-fail '@jq@' '${jq}'
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
