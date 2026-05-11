# config file for keyd


{config, pkgs, ...}:
{
	environment.systemPackages = with pkgs; [	
	];

	services.keyd = {
	  enable = true;
	  keyboards.default = {
	    ids = [ "*" ];
	    settings = {
	      main = {
	        left = "noop";
	        right = "noop";
	        up = "noop";
	        down = "noop";
	
	        "alt+h" = "left";
	        "alt+l" = "right";
	        "alt+j" = "down";
	        "alt+k" = "up";
	        "alt+y" = "C-left";
	        "alt+o" = "C-right";
	        "alt+u" = "pagedown";
	        "alt+i" = "pageup";
	
	        "alt+shift+h" = "S-left";
	        "alt+shift+l" = "S-right";
	        "alt+shift+j" = "S-down";
	        "alt+shift+k" = "S-up";
	        "alt+shift+y" = "C-S-left";
	        "alt+shift+o" = "C-S-right";
	        "alt+shift+u" = "S-pagedown";
	        "alt+shift+i" = "S-pageup";
	
	        "alt+c" = "C-c";
	        "alt+v" = "C-v";
	        "alt+x" = "C-x";
	        "alt+s" = "C-s";
	        "alt+z" = "C-z";
	        "alt+f" = "C-f";
	        "alt+a" = "C-a";
	        "alt+e" = "C-e";
	        "alt+b" = "C-b";
	        "alt+n" = "C-n";
	        "alt+d" = "C-d";
	
	        "alt+q" = "esc";
	        "alt+backslash" = "delete";
	        "alt+semicolon" = "backspace";
	        "alt+apostrophe" = "C-backspace";
	
	        "alt+space" = "layer(space_layer)";
	      };
	
	      "space_layer" = {
	        a = "1";
	        s = "2";
	        d = "3";
	        f = "4";
	        g = "5";
	        h = "6";
	        j = "7";
	        k = "8";
	        l = "9";
	        semicolon = "0";
	        apostrophe = "-";
	        q = "!";
	        w = "@";
	        e = "#";
	        r = "$";
	        t = "%";
	        y = "^";
	        u = "&";
	        i = "*";
	        o = "(";
	        p = ")";
	        leftbrace = "_";
	        rightbrace = "+";
	        enter = "=";
	        capslock = "`";
	        tab = "~";
	      };
	    };
	  };
	};
}

