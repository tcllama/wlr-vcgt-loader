# Validating VCGT Calibration

This document describes how to verify that wlr-vcgt-loader is correctly
applying the VCGT curves from your ICC profile.

## 1. Visual Smoke Test

The simplest check: run the tool and watch your screen.

```
wlr-vcgt-loader -p ~/my-display.icc -o DP-1 &
```

Calibration profiles typically reduce brightness slightly and shift the white
point. You should see a visible change — often a subtle warm or cool shift and
slightly reduced contrast. If the screen looks identical, something is wrong.

Kill the process and the screen should snap back to its uncalibrated appearance:

```
kill %1
```

If you see no change at all, verify:
- The profile actually contains a VCGT tag (see section 2)
- The output name matches (`swaymsg -t get_outputs | grep name`)
- No other gamma client is running (gammastep, wlsunset)

## 2. Inspect the VCGT Curves

Before testing on a live display, confirm the ICC profile contains meaningful
VCGT data.

### Using iccdump (from ArgyllCMS)

```
iccdump -v3 -t vcgt ~/my-display.icc
```

This prints the VCGT tag contents. You should see per-channel curve data — either
parametric curves or a table of values. If it says the tag is not present, the
profile has no calibration curves and wlr-vcgt-loader will refuse to load it.

### Using xicclu (from ArgyllCMS)

Evaluate what the VCGT curves do to specific input values:

```
# Feed normalized input values (0.0 to 1.0) through the VCGT
echo "0.0" | xicclu -ir ~/my-display.icc
echo "0.5" | xicclu -ir ~/my-display.icc
echo "1.0" | xicclu -ir ~/my-display.icc
```

The `-ir` flag selects the reverse lookup through calibration curves. A linear
(uncorrected) display would return the input unchanged. Deviations from linearity
show the corrections the VCGT applies.

### Using Python with pillow/colour-science

```python
import struct
from pathlib import Path

# Read raw VCGT table entries from an ICC profile
# (requires the 'colour' package: pip install colour-science)
import colour

profile = colour.io.read_LUT("~/my-display.icc")
# Or use ImageCms from Pillow to inspect the profile
from PIL import ImageCms
p = ImageCms.getOpenProfile("~/my-display.icc")
```

## 3. Measure with a Colorimeter

This is the definitive test. Use a hardware colorimeter (i1Display Pro, Spyder,
ColorMunki, etc.) with ArgyllCMS to measure actual display output and save the
results. The procedure below covers both Wayland and X11 so you can compare
them directly.

The included `validate.sh` script automates this entire procedure
interactively. Run `./validate.sh` to be walked through each step. The manual
commands are documented below for reference.

### Prerequisites

- ArgyllCMS installed (`spotread`, `dispread`, `targen`, `colverify`)
- A supported colorimeter connected via USB
- The ICC profile you want to validate

Identify your colorimeter with `spotread -?` and note the `-d` number (e.g.
`-d1` for the first instrument). All commands below use `-d1`; substitute your
own.

On Wayland, ArgyllCMS patch windows go through Xwayland. The VCGT gamma ramp
affects the entire output including Xwayland surfaces, so the colorimeter will
measure the effect of the loaded calibration regardless of how the patches are
displayed.

### 3a. Generate a Test Chart

Create a set of measurement patches. A small chart (50-100 patches) is enough
for validation. This only needs to be done once — the same `.ti1` file is
reused for both X11 and Wayland measurements.

```
mkdir -p ~/vcgt-validation && cd ~/vcgt-validation

# Generate a 79-patch chart (white, black, grays, primaries, secondaries, etc.)
targen -d3 -G -f 79 validation
```

This produces `validation.ti1`. The `-d3` flag targets a display device and
`-G` adds extra gray-axis patches, which are most sensitive to VCGT corrections.

### 3b. Measure on Wayland

**Uncalibrated baseline:**

```
cd ~/vcgt-validation

# Make sure no calibration is active
killall wlr-vcgt-loader 2>/dev/null

# Measure all patches — results go to validation-wayland-uncal.ti3
dispread -d1 -yw -P 0.5,0.5,1.0 validation-wayland-uncal
```

- `-yw` sets the display type (wide-gamut LED). Use `-yc` for CCFL, `-yl` for
  standard LED. This affects the colorimeter's correction matrix.
- `-P 0.5,0.5,1.0` positions the patch window at center-screen, full size.
  Adjust to place it under your colorimeter.

**Calibrated:**

```
# Load the VCGT
wlr-vcgt-loader -p ~/my-display.icc -o DP-1 &

# Wait a moment for the gamma to take effect, then measure
sleep 1
dispread -d1 -yw -P 0.5,0.5,1.0 validation-wayland-cal
```

You now have:
- `validation-wayland-uncal.ti3` — uncalibrated measurements
- `validation-wayland-cal.ti3` — calibrated measurements

### 3c. Measure on X11

If you have access to an X11 session on the same display, measure there too.
This lets you compare wlr-vcgt-loader against the known-good `dispwin` loader.

```
cd ~/vcgt-validation

# Load VCGT through X11's gamma ramp (the established method)
dispwin ~/my-display.icc

# Measure
dispread -d1 -yw -P 0.5,0.5,1.0 validation-x11-cal
```

On X11, `dispread` can also load calibration itself via `-K` to use the
profile's calibration curves directly:

```
dispread -d1 -yw -K ~/my-display.icc -P 0.5,0.5,1.0 validation-x11-ref
```

### 3d. Compare Results

#### Wayland uncalibrated vs. calibrated

```
colverify -v validation-wayland-uncal.ti3 validation-wayland-cal.ti3
```

This reports per-patch delta-E values. You should see meaningful differences —
if all delta-E values are near zero, the VCGT had no effect.

#### Wayland vs. X11

This is the key comparison. If wlr-vcgt-loader is applying the same gamma ramp
as `dispwin`, the measurements should be nearly identical.

```
colverify -v validation-wayland-cal.ti3 validation-x11-cal.ti3
```

What to expect:

| Average delta-E | Interpretation |
|-----------------|----------------|
| < 0.5 | Match — wlr-vcgt-loader and dispwin produce the same result |
| 0.5 - 1.0 | Minor differences — likely measurement noise or ambient variation |
| 1.0 - 2.0 | Small discrepancy — investigate LUT rounding or gamma ramp size differences |
| > 2.0 | Significant mismatch — something is wrong |

#### Verify against profile target

Compare calibrated measurements against the profile's expected values:

```
# Create a profile from the calibrated measurements for comparison
colprof -v -D ~/my-display.icc -ax validation-wayland-cal

# Or verify measurements against the existing profile directly
profcheck -v validation-wayland-cal.ti3 ~/my-display.icc
```

`profcheck` reports how well the measured display matches the profile's
predictions. Low delta-E values mean the calibration is working correctly.

### 3e. Quick Spot-Check with spotread

For a fast sanity check without generating a full test chart, use `spotread` to
measure individual colors interactively.

```
# Start spotread in emissive display mode
spotread -d1 -ew
```

`spotread` displays a color patch on screen and waits for you to trigger a
measurement. It reports XYZ and Lab values after each reading.

**White point check:**

1. Kill wlr-vcgt-loader, measure a white patch, note the xy chromaticity
2. Start wlr-vcgt-loader, measure white again
3. The calibrated white point should be closer to the profile's target
   (typically D65: x=0.3127, y=0.3290)

**Gray ramp check:**

Measure 25%, 50%, and 75% gray patches with and without calibration. The
calibrated grays should track a straighter line toward the white point in xy
space, indicating the VCGT is correcting per-channel nonlinearities.

### 3f. Saving and Organizing Results

A suggested directory layout for ongoing validation:

```
~/vcgt-validation/
    validation.ti1                    # test chart (reuse across sessions)
    2025-03-15/
        wayland-uncal.ti3             # baseline
        wayland-cal.ti3               # with wlr-vcgt-loader
        x11-cal.ti3                   # with dispwin (if available)
        notes.txt                     # ambient conditions, instrument, etc.
    2025-06-20/
        ...                           # re-validate after recalibration
```

Record ambient conditions (room lighting, display warm-up time) alongside the
`.ti3` files. Colorimeters are sensitive to ambient light — measure in
consistent conditions for meaningful comparisons. Let the display warm up for at
least 30 minutes before measuring.

## 4. Verify the Gamma Ramp Numerically

You can cross-check the LUT values that wlr-vcgt-loader generates against what
the profile's VCGT curves should produce.

### Extract expected values with xicclu

```
# Evaluate VCGT at several points and save expected output
for v in 0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0; do
    echo "$v $v $v" | xicclu -ir ~/my-display.icc
done
```

### Compare with a test build

Add a temporary printf to `generate_gamma_table()` in `main.c` to dump the LUT:

```c
for (uint32_t i = 0; i < gamma_size; i++) {
    cmsFloat32Number in = (cmsFloat32Number)i / (cmsFloat32Number)(gamma_size - 1);
    float rv = cmsEvalToneCurveFloat(vcgt[0], in);
    float gv = cmsEvalToneCurveFloat(vcgt[1], in);
    float bv = cmsEvalToneCurveFloat(vcgt[2], in);
    r[i] = (uint16_t)(rv * (double)0xFFFF);
    g[i] = (uint16_t)(gv * (double)0xFFFF);
    b[i] = (uint16_t)(bv * (double)0xFFFF);
    if (i % (gamma_size / 10) == 0) {
        fprintf(stderr, "  [%3u] in=%.4f  R=%.4f G=%.4f B=%.4f\n",
            i, in, rv, gv, bv);
    }
}
```

The float values (0.0-1.0) should match the xicclu output for the same input
positions. If they diverge, there may be an issue with how the profile's VCGT
is encoded.

## 5. Compare Against X11 Reference

If you have access to an X11 session (or Xwayland), you can load the same
profile with a known-good tool and compare results.

### Using dispwin (ArgyllCMS)

```
# On X11, load the calibration
dispwin ~/my-display.icc

# Dump the current X11 gamma ramp
xgamma -gamma 1.0    # prints current values
# Or use dispwin to read it back
dispwin -s           # shows the installed calibration curves
```

Compare the gamma ramp values with the output from the test build above. The
16-bit LUT values should match.

### Using xcalib

```
# Load on X11
xcalib ~/my-display.icc

# Read back
xcalib -p
```

## 6. Troubleshooting

| Symptom | Likely Cause |
|---------|-------------|
| No visible change | Wrong output name, or another gamma client has exclusive access |
| Screen too dark | Profile was made for a different display; VCGT curves are display-specific |
| Colors look wrong | Profile may target a white point far from what you expect (e.g. D50 for print work) |
| "ICC profile has no VCGT tag" | Profile is characterization-only; needs to be re-created with calibration enabled |
| "gamma control failed" | Another client (gammastep, wlsunset) already holds gamma control on that output |
| Values don't match xicclu | Check that you're using the same profile file and that it hasn't been regenerated |

## Summary

| Method | What it proves | Effort |
|--------|---------------|--------|
| Visual check | Gamma is being applied at all | Low |
| iccdump/xicclu | Profile contains valid VCGT data | Low |
| Numerical LUT dump | Tool evaluates VCGT curves correctly | Medium |
| spotread spot-check | White point and grays shift as expected | Medium |
| dispread + colverify | Wayland matches X11 to within measurement noise | High |
| profcheck against profile | Calibrated display matches profile predictions | High |
