# desktop packages here

{ inputs, config, pkgs, lib, ... }:
{
        environment.systemPackages = with pkgs; [
    		slack
    		postman
    		wineWow64Packages.stable
        ];
}
