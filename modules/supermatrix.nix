{ ... }:
{
	# Super Matrix on the matrix host. DNS (grey cloud / DNS only, not
	# proxied): aidan.supermatrix.io A 13.184.85.196, plus an A record per
	# domain added in the app (*.example.com or an exact host) to the same IP.
	#
	# The root password (the app login), put on the box once:
	#   sudo install -D -m 600 /dev/stdin /etc/supermatrix/root-password
	# It's read via LoadCredential, so it never enters the Nix store.
	services.supermatrix = {
		enable = true;
		adminHost = "aidan.supermatrix.io";
		acmeEmail = "aidan@lunargen.com";
		# Let's Encrypt staging until the first certs come through; then set
		# false, `sudo rm -rf /var/lib/supermatrix/data/certs` and rebuild.
		acmeStaging = true;
		rootPasswordFile = "/etc/supermatrix/root-password";
	};
}
