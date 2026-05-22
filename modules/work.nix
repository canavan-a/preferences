# desktop packages here

{ inputs, config, pkgs, lib, ... }:
{
        environment.systemPackages = with pkgs; [
    		slack
    		postman
    		wineWowPackages.stable
        ];
}
