self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.wlr-vcgt-loader;
in
{
  options.services.wlr-vcgt-loader = {
    enable = lib.mkEnableOption "wlr-vcgt-loader VCGT calibration";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.wlr-vcgt-loader;
      defaultText = lib.literalExpression "inputs.wlr-vcgt-loader.packages.\${pkgs.stdenv.hostPlatform.system}.wlr-vcgt-loader";
      description = "The wlr-vcgt-loader package to use.";
    };

    displays = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.profile = lib.mkOption {
          type = lib.types.path;
          description = "Path to the ICC profile containing a VCGT tag.";
        };
      });
      default = { };
      description = ''
        Per-display VCGT calibration configuration, keyed by Wayland output
        name (e.g. "DP-1", "HDMI-A-1").
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.displays != { };
        message = "services.wlr-vcgt-loader.displays must contain at least one display when enabled.";
      }
    ];

    systemd.user.services = lib.mapAttrs' (name: display:
      lib.nameValuePair "wlr-vcgt-loader-${name}" {
        Unit = {
          Description = "wlr-vcgt-loader VCGT calibration for ${name}";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };

        Service = {
          Type = "simple";
          ExecStart = "${lib.getExe cfg.package} -o ${lib.escapeShellArg name} -p ${lib.escapeShellArg (toString display.profile)}";
          Restart = "on-failure";
          RestartSec = 5;
        };

        Install = {
          WantedBy = [ "graphical-session.target" ];
        };
      }
    ) cfg.displays;
  };
}
