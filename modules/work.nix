# desktop packages here

{ inputs, config, pkgs, lib, ... }:
{
        environment.systemPackages = with pkgs; [
    		slack
    		wineWow64Packages.stable
    		ansible
        ];
}
