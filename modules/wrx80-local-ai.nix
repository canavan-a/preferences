{ config, pkgs, ...}:
{
	environment.systemPackages = with pkgs; [
		  libdrm.out
		  (writeShellScriptBin "rocm-smi" ''
		      export LD_LIBRARY_PATH=${libdrm.out}/lib:$LD_LIBRARY_PATH
		      exec ${rocmPackages.rocm-smi}/bin/rocm-smi "$@"
		  '')
	];

	# mutableUsers stays true (default), so passwords set with `passwd`
	# persist across rebuilds. The account itself is declared here so a
	# clean reinstall always recreates it; set its password after install.
	users.users.llm = {
		isNormalUser = true;
		description = "llm";
		extraGroups = [ "networkmanager" "wheel" ];
	};
}

