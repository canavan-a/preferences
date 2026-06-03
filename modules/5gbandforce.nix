{ ... }:
{
	networking.networkmanager.ensureProfiles.profiles = {
		"A2" = {
			connection = {
				id = "A2";
				type = "802-11-wireless";	
			};
			wifi = {
				band = "a";
			};
		};
	};
}
