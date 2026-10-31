{ lib
, stdenv
, fetchFromGitHub
, cmake
, ninja
, python3
, rocmPackages
# gfx1100 = RX 7900 XT / XTX. A list builds one binary for several archs.
, gpuTargets ? [ "gfx1100" ]
}:
let
	version = "0.1.43.1";

	# The llama.cpp commit Strata's CMakeLists.txt pins (FetchContent). The
	# sandbox has no network, so it is handed in through STRATA_GGML_DIR; the
	# pack tools also need its gguf-py at runtime (STRATA_GGUF_PY).
	llamaSrc = fetchFromGitHub {
		owner = "ggml-org";
		repo = "llama.cpp";
		rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
		hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
	};

	# Server + pack tools (requirements.txt, versions from nixpkgs not its pins).
	python = python3.withPackages (ps: with ps; [
		numpy jinja2 regex pyyaml tqdm requests pillow psutil
	]);
in
stdenv.mkDerivation {
	pname = "strata";
	inherit version;

	src = fetchFromGitHub {
		owner = "Niko1221";
		repo = "Strata";
		rev = "a0116b2782a5b82622358c04a06496485d12b2d6";
		hash = "sha256-ouJseBgkuS0WxgHgHw8vxuNNqR/B3W5yjbjfBzkBpqA=";
	};

	nativeBuildInputs = [ cmake ninja python3 ];
	buildInputs = with rocmPackages; [ clr hipblas rocblas hipblaslt ];

	# Same flags setup.py's build_engine_hip uses, except STRATA_PORTABLE:
	# an AVX2 ggml-cpu instead of -march=native of whichever host builds it
	# (the 3955WX has no AVX-512, so nothing is lost on wrx).
	cmakeFlags = [
		(lib.cmakeBool "STRATA_ENABLE_HIP" true)
		(lib.cmakeBool "STRATA_ENABLE_CUDA" false)
		(lib.cmakeBool "STRATA_PREFILL_MMQ" true)
		(lib.cmakeBool "STRATA_PORTABLE" true)
		(lib.cmakeBool "STRATA_BUILD_TESTS" false)
		(lib.cmakeFeature "STRATA_GGML_DIR" "${llamaSrc}")
		(lib.cmakeFeature "CMAKE_HIP_COMPILER" "${rocmPackages.clr.hipClangPath}/clang++")
		(lib.cmakeFeature "CMAKE_HIP_ARCHITECTURES" (lib.concatStringsSep ";" gpuTargets))
		(lib.cmakeFeature "CMAKE_BUILD_TYPE" "Release")
	];

	# Only what the server runs, plus the hipBLASLt tuner (makes a prompt
	# GEMM table for this ROCm's hipBLASLt; see docs/AMD_HIP.md).
	ninjaFlags = [ "strata" "strata-device" "tune_hipblaslt" ];

	# Upstream has no install() rules.
	installPhase = ''
		runHook preInstall
		mkdir -p $out/libexec/strata $out/bin $out/share/strata
		install -m755 strata strata-device tune_hipblaslt $out/libexec/strata/
		ln -s $out/libexec/strata/strata-device $out/bin/strata-device
		cp -r $src/serve $src/tools $src/data $src/chat.py $src/requirements.txt $out/share/strata/
		runHook postInstall
	'';

	passthru = { inherit python llamaSrc; };

	meta = {
		description = "Strata MoE inference engine (HIP build) with its OpenAI/Anthropic server";
		homepage = "https://github.com/Niko1221/Strata";
		license = lib.licenses.mit;
		platforms = [ "x86_64-linux" ];
		mainProgram = "strata-device";
	};
}
