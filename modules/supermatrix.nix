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
		# Real Let's Encrypt certs (staging was only for the first run). To go
		# back to staging, set true, `sudo rm -rf /var/lib/supermatrix/data/certs`
		# and rebuild.
		acmeStaging = false;
		rootPasswordFile = "/etc/supermatrix/root-password";
		# SMTP for email-code sign-in, put on the box once:
		#   sudo install -D -m 600 /dev/stdin /etc/supermatrix/env
		# with SUPERMATRIX_SMTP_HOST/_PORT/_EMAIL/_APP_PASSWORD lines.
		environmentFile = "/etc/supermatrix/env";
	};
}
