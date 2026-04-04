# wlr-vcgt-loader

Apply ICC profile VCGT (Video Card Gamma Table) calibration curves on Wayland
compositors that support the `wlr-gamma-control-unstable-v1` protocol (sway,
Hyprland, river, etc.).

Hardware calibration tools like DisplayCAL and ArgyllCMS write per-channel tone
correction curves into the VCGT tag of an ICC profile. On X11, `xcalib` or
`dispwin` load these into the X server's gamma ramp. On Wayland there has been
no equivalent — this tool fills that gap.

## Dependencies

- `wayland-client` (>= 1.20)
- `lcms2` (>= 2.6)
- `wayland-scanner` (build-time)

## Building

```
make
```

Or with Nix:

```
nix build
```


For local development and tests:

```
nix develop
make test
```

## Optional: enable the Cachix binary cache

Using the public Cachix cache can significantly reduce build time.

If you already have `cachix` installed, run:

```sh
cachix use tcllama
```

Or add the cache manually to your Nix settings:

```nix
nix.settings = {
  substituters = [
    "https://tcllama.cachix.org"
  ];
  trusted-public-keys = [
    "tcllama.cachix.org-1:lwfv8+bXn43j8VdlKIlutiX9vHpBfAc0fCkoAJFdbxU="
  ];
};
```

On non-NixOS systems, you can add the equivalent settings to `~/.config/nix/nix.conf`.

## Usage

```
wlr-vcgt-loader -p <profile.icc> -o <output-name>
```

| Option | Description |
|--------|-------------|
| `-p, --profile <path>` | Path to ICC profile containing VCGT tag |
| `-o, --output <name>` | Wayland output name (e.g. `DP-1`, `HDMI-A-1`) |
| `-h, --help` | Show help |

Find your output names with `swaymsg -t get_outputs` or `wlr-randr`.

The process must stay running — the compositor resets the gamma table when the
client disconnects. Kill the process to restore the original gamma.

```
wlr-vcgt-loader -p ~/my-display.icc -o DP-1 &
# ... later ...
kill %1   # gamma reverts to default
```

## How it works

1. Opens the ICC profile with LCMS2 and reads the `cmsSigVcgtTag`
1. Connects to the Wayland compositor and binds the target output
1. Acquires exclusive gamma control via `zwlr_gamma_control_manager_v1`
1. Evaluates the VCGT tone curves into a 16-bit LUT sized to the output's
   gamma ramp
1. Writes the LUT to a memfd and sends it to the compositor
1. Stays connected to keep the gamma active

## Validation

An interactive script is included to walk through colorimeter-based validation
of the applied calibration, with support for comparing Wayland and X11 results:

```
./validate.sh
```

It handles test chart generation, measurement with `dispread`, and comparison
with `colverify` and `profcheck`. Requires ArgyllCMS and a supported colorimeter.
See [VALIDATION.md](VALIDATION.md) for the full methodology.

## Notes

- The ICC profile **must** contain a VCGT tag. Profiles without one (e.g. plain
  sRGB) will be rejected with an error.
- `wlr-vcgt-loader` is exclusive — only one client per output. This tool
  cannot run simultaneously with gammastep or wlsunset on the same output.

## Install

```
make install          # installs to /usr/local/bin
make PREFIX=~/.local install   # installs to ~/.local/bin
```

### NixOS / Home Manager

Add the flake to your inputs:

```nix
inputs.wlr-vcgt-loader.url = "git+https://codeberg.org/tcllama/wlr-vcgt-loader.git";
```

#### Home Manager module

Import the module and configure per-display calibration declaratively. A
systemd user service is created for each display that starts with your
graphical session and restarts on failure.

```nix
{
  imports = [ inputs.wlr-vcgt-loader.homeManagerModules.default ];

  services.wlr-vcgt-loader = {
    enable = true;
    displays = {
      "DP-1" = { profile = "/home/user/.local/share/icc/dp1.icc"; };
      "HDMI-A-1" = { profile = ./icc/hdmi.icc; };  # nix path literals also work
    };
  };
}
```
