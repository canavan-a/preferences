# config file for keyd
{config, pkgs, ...}:
{
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
        };
        leftalt = {
          h = "left";
          l = "right";
          j = "down";
          k = "up";
          y = "C-left";
          o = "C-right";
          u = "pagedown";
          i = "pageup";
          c = "C-c";
          v = "C-v";
          x = "C-x";
          s = "C-s";
          z = "C-z";
          f = "C-f";
          a = "C-a";
          e = "C-e";
          b = "C-b";
          n = "C-n";
          d = "C-d";
          q = "esc";
          backslash = "delete";
          semicolon = "backspace";
          apostrophe = "C-backspace";
          space = "layer(space_layer)";
        };
        "leftalt+shift" = {
          h = "S-left";
          l = "S-right";
          j = "S-down";
          k = "S-up";
          y = "C-S-left";
          o = "C-S-right";
          u = "S-pagedown";
          i = "S-pageup";
        };
        space_layer = {
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