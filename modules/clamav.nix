{ pkgs, ... }:

let
  scanScript = pkgs.writeShellScript "clamav-scan" ''
    LOGFILE="/var/log/clamav/scan.log"
    RESULT=$(${pkgs.clamav}/bin/clamdscan --infected --multiscan --fdpass \
      --exclude-dir='^/nix/store' \
      --exclude-dir='^/home/nixos/.cache' \
      /home/nixos 2>&1)
    STATUS=$?
    echo "$RESULT" >> "$LOGFILE"
    if [ $STATUS -ne 0 ]; then
      DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        ${pkgs.libnotify}/bin/notify-send \
          -u critical "ClamAV Alert" "Threats detected! Check $LOGFILE"
    else
      DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        ${pkgs.libnotify}/bin/notify-send \
          -u low "ClamAV" "Scan complete. No threats found."
    fi
  '';
in
{
  services.clamav.daemon.enable = true;
  services.clamav.updater.enable = true;

  services.clamav.daemon.settings = {
    ExcludePath = [
      "^/nix/store"
      "^/home/nixos/.cache"
      "^/proc"
      "^/sys"
      "^/dev"
      "^/tmp"
	  "^/run"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/log/clamav 0755 nixos users -"
  ];

  systemd.services.clamav-scan = {
    description = "ClamAV home scan";
    after = [ "clamav-daemon.service" ];
    requires = [ "clamav-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${scanScript}";
      User = "nixos";
    };
  };

  systemd.timers.clamav-scan = {
    description = "Daily ClamAV scan timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily 17:00";
      Persistent = true;
    };
  };
}
