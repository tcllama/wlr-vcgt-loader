#!/usr/bin/env bash
set -euo pipefail

# --- Configuration (overridable via environment) ---
VALIDATION_DIR="${VALIDATION_DIR:-$HOME/vcgt-validation}"
PATCH_COUNT="${PATCH_COUNT:-79}"

# --- State ---
SESSION_DIR=""
ICC_PROFILE=""
OUTPUT_NAME=""
DISPLAY_TYPE=""
DISPLAY_TYPE_SET=0
INSTRUMENT=""
PATCH_POS="0.5,0.5,1.0"
LOADER_PID=""

# --- Helpers ---

die() {
	echo "ERROR: $*" >&2
	exit 1
}

bold() { printf '\033[1m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
yellow() { printf '\033[33m%s\033[0m' "$*"; }
red() { printf '\033[31m%s\033[0m' "$*"; }

ask() {
	local prompt="$1" var="$2" default="${3:-}"
	if [ -n "$default" ]; then
		printf '%s [%s]: ' "$(bold "$prompt")" "$default"
	else
		printf '%s: ' "$(bold "$prompt")"
	fi
	read -r val
	val="${val:-$default}"
	[ -z "$val" ] && die "No value provided for: $prompt"
	printf -v "$var" '%s' "$val"
}

ask_yn() {
	local prompt="$1" default="${2:-y}"
	local hint="Y/n"
	[ "$default" = "n" ] && hint="y/N"
	printf '%s [%s]: ' "$(bold "$prompt")" "$hint"
	read -r yn
	yn="${yn:-$default}"
	case "$yn" in
	[Yy]*) return 0 ;;
	*) return 1 ;;
	esac
}

pause() {
	echo
	printf '%s' "$(bold "Press Enter to continue...")"
	read -r _
}

float_lt() { awk "BEGIN{exit !($1 < $2)}"; }

get_luminance_y() {
	awk '/^LUMINANCE_XYZ_CDM2/{print $3}' "$1"
}

get_dispcal_brightness() {
	local type_flag=()
	if [ -n "$DISPLAY_TYPE" ]; then
		type_flag=("$DISPLAY_TYPE")
	fi
	dispcal -r -c "$INSTRUMENT" "${type_flag[@]}" -P "$PATCH_POS" 2>&1 |
		awk '/White level =/{print $4}'
}

step_brightness_check() {
	local target_file="$1" target_label="$2"

	echo
	echo "  $(bold "--- Brightness Check ---")"

	local target_y=""
	if [ -f "$target_file" ]; then
		target_y=$(get_luminance_y "$target_file")
	fi

	if [ -n "$target_y" ]; then
		echo "  Target: $target_y cd/m² (from $target_label measurement)"
	else
		echo "  No $target_label measurement yet — brightness matching not available."
		return 0
	fi

	echo
	if ! ask_yn "  Check current brightness with dispcal?"; then
		return 0
	fi

	while true; do
		echo "  dispcal will display a white test patch and measure."
		echo "  Position your colorimeter and follow its prompts."
		echo "  Measuring..."
		local current_y
		current_y=$(get_dispcal_brightness)

		if [ -z "$current_y" ]; then
			echo "  $(yellow "Could not read brightness from dispcal.")"
			break
		fi

		echo "  Current: $current_y cd/m²"

		local pct_diff
		pct_diff=$(awk "BEGIN{avg=($target_y+$current_y)/2; diff=$target_y-$current_y; if(diff<0)diff=-diff; printf \"%.1f\", (diff/avg)*100}")

		if float_lt "$pct_diff" 2.0; then
			echo "  Difference: $(green "${pct_diff}% — negligible")"
		elif float_lt "$pct_diff" 5.0; then
			echo "  Difference: $(yellow "${pct_diff}% — minor")"
		else
			echo "  Difference: $(red "${pct_diff}% — significant, adjust display brightness")"
		fi

		echo
		if ! ask_yn "  Adjust and re-check?"; then
			break
		fi
	done
}

compare_brightness() {
	local file1="$1" file2="$2" label1="$3" label2="$4"

	local y1 y2
	y1=$(get_luminance_y "$file1")
	y2=$(get_luminance_y "$file2")

	# Silently return if either file lacks luminance data
	[ -z "$y1" ] || [ -z "$y2" ] && return 0

	local pct_diff
	pct_diff=$(awk "BEGIN{avg=($y1+$y2)/2; diff=$y1-$y2; if(diff<0)diff=-diff; printf \"%.1f\", (diff/avg)*100}")

	echo
	echo "  $(bold "Brightness:")"
	echo "    $label1: ${y1} cd/m²"
	echo "    $label2: ${y2} cd/m²"

	if float_lt "$pct_diff" 2.0; then
		echo "    Difference: $(green "${pct_diff}% — negligible.")"
	elif float_lt "$pct_diff" 5.0; then
		echo "    Difference: $(yellow "${pct_diff}% — minor brightness mismatch; may contribute to L* error.")"
	else
		echo "    Difference: $(red "${pct_diff}% — significant brightness mismatch; likely explains L* error.")"
	fi
}

interpret_colverify() {
	local output="$1"

	# Parse values from colverify output
	local avg worst10_avg best90_avg avg_L avg_a avg_b
	avg=$(echo "$output" | awk '/^ *Total errors:/{for(i=1;i<=NF;i++) if($i=="avg"){print $(i+2);exit}}')
	worst10_avg=$(echo "$output" | awk '/Worst 10%/{for(i=1;i<=NF;i++) if($i=="avg"){print $(i+2);exit}}')
	best90_avg=$(echo "$output" | awk '/Best  90%/{for(i=1;i<=NF;i++) if($i=="avg"){print $(i+2);exit}}')
	avg_L=$(echo "$output" | awk '/avg err L\*/{for(i=1;i<=NF;i++) if($i=="L*"){v=$(i+1);sub(/,/,"",v);print v;exit}}')
	avg_a=$(echo "$output" | awk '/avg err L\*/{for(i=1;i<=NF;i++) if($i=="a*"){v=$(i+1);sub(/,/,"",v);print v;exit}}')
	avg_b=$(echo "$output" | awk '/avg err L\*/{for(i=1;i<=NF;i++) if($i=="b*"){print $(i+1);exit}}')

	[ -z "$avg" ] && return

	echo
	echo "  $(bold "Interpretation:")"

	if float_lt "$avg" 0.5; then
		echo "  $(green "Excellent match.") wlr-vcgt-loader and dispwin produce virtually"
		echo "  identical results (avg dE $avg). The VCGT curves are being applied"
		echo "  correctly on Wayland."
	elif float_lt "$avg" 1.0; then
		echo "  $(green "Good match.") Differences are below the threshold of visual"
		echo "  perception (avg dE $avg). Any variation is likely measurement noise"
		echo "  or minor rounding in gamma ramp interpolation."
	elif float_lt "$avg" 2.0; then
		echo "  $(yellow "Acceptable.") Small discrepancies detected (avg dE $avg)."
		echo "  Possible causes: gamma ramp resolution differences, interpolation"
		echo "  method, or measurement variability between sessions."
	elif float_lt "$avg" 5.0; then
		echo "  $(yellow "Noticeable differences") (avg dE $avg). The calibration results"
		echo "  differ visibly. Check for gamma ramp size mismatch, VCGT extraction"
		echo "  issues, or display state changes between measurements."
	else
		echo "  $(red "Significant mismatch") (avg dE $avg). The Wayland and X11"
		echo "  calibration results are very different. Possible causes:"
		echo "    - wlr-vcgt-loader may not be applying the VCGT correctly"
		echo "    - The compositor gamma interface may not be functioning"
		echo "    - Measurements were taken under different display conditions"
	fi

	# Diagnose error components for larger discrepancies
	if [ -n "$avg_L" ] && [ -n "$avg_a" ] && [ -n "$avg_b" ] && ! float_lt "$avg" 2.0; then
		echo
		echo "  $(bold "Error breakdown:")"
		echo "    Lightness (L*): $avg_L"
		echo "    Green-Red (a*): $avg_a"
		echo "    Blue-Yellow (b*): $avg_b"

		local dominant="L*" dom_val="$avg_L" dom_desc="lightness"
		if float_lt "$dom_val" "$avg_a"; then
			dominant="a*"
			dom_val="$avg_a"
			dom_desc="green-red (chromatic)"
		fi
		if float_lt "$dom_val" "$avg_b"; then
			dominant="b*"
			dom_val="$avg_b"
			dom_desc="blue-yellow (chromatic)"
		fi
		echo
		echo "  The dominant error is in $dom_desc ($dominant = $dom_val)."
		case "$dominant" in
		"L*")
			echo "  This suggests a tone response curve (TRC) difference between"
			echo "  the Wayland and X11 gamma ramp handling."
			;;
		"a*")
			echo "  This suggests a difference in how red/green channel calibration"
			echo "  curves are being applied."
			;;
		"b*")
			echo "  This suggests a difference in how blue channel calibration"
			echo "  curves are being applied."
			;;
		esac
	fi

	# Outlier check: if worst 10% is much worse than best 90%
	if [ -n "$worst10_avg" ] && [ -n "$best90_avg" ] && ! float_lt "$best90_avg" 0.001; then
		local ratio
		ratio=$(awk "BEGIN{printf \"%.1f\", $worst10_avg / $best90_avg}")
		if awk "BEGIN{exit !($ratio > 3.0)}"; then
			echo
			echo "  $(bold "Note:") The worst 10% of patches (avg dE $worst10_avg) are ${ratio}x"
			echo "  worse than the best 90% (avg dE $best90_avg), indicating a few"
			echo "  specific colors are causing most of the error. This often points to"
			echo "  clipping or gamut-boundary issues rather than a systematic problem."
		fi
	fi
}

interpret_profcheck() {
	local output="$1" label="$2"

	local pc_max pc_avg
	pc_max=$(echo "$output" | awk '/errors:/{gsub(/.*max\. = /,"");gsub(/,.*/,"");print}')
	pc_avg=$(echo "$output" | awk '/errors:/{gsub(/.*avg\. = /,"");gsub(/,.*/,"");print}')

	[ -z "$pc_avg" ] && return

	echo
	echo "  $(bold "Interpretation:")"

	if float_lt "$pc_avg" 1.0; then
		echo "  $(green "Excellent.") The $label calibrated display closely matches the ICC"
		echo "  profile predictions (avg dE $pc_avg). Calibration is accurate."
	elif float_lt "$pc_avg" 2.0; then
		echo "  $(green "Good.") The $label display matches the ICC profile within typical"
		echo "  calibration and measurement tolerance (avg dE $pc_avg)."
	elif float_lt "$pc_avg" 4.0; then
		echo "  $(yellow "Acceptable.") Some deviation from the ICC profile (avg dE $pc_avg)."
		echo "  The calibration is functional but may benefit from re-profiling"
		echo "  or checking the VCGT application method."
	elif float_lt "$pc_avg" 10.0; then
		echo "  $(yellow "Poor.") Significant deviation from the ICC profile (avg dE $pc_avg)."
		echo "  The VCGT calibration may not be applied correctly, or the display"
		echo "  characteristics may have drifted since profiling."
	else
		echo "  $(red "Very poor.") The display output does not match the ICC profile"
		echo "  (avg dE $pc_avg). The VCGT curves are likely not being applied"
		echo "  correctly, or the wrong profile is being used."
	fi

	if [ -n "$pc_max" ] && awk "BEGIN{exit !($pc_max > $pc_avg * 3)}"; then
		echo
		echo "  $(bold "Note:") The peak error ($pc_max) is much larger than the average"
		echo "  ($pc_avg). A few patches (likely saturated colors near the gamut"
		echo "  boundary) have large errors while overall accuracy is better than"
		echo "  the peak suggests."
	fi
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
  create     Generate test chart and measure display
  compare    Compare measurement results
  (none)     Interactive mode with full menu

Options:
  -p PATH    ICC profile path
  -o NAME    Wayland output name (e.g. DP-1)
  -s DIR     Session directory (default: auto-created under \$VALIDATION_DIR)
  -n COUNT   Patch count (default: $PATCH_COUNT)
  -d TYPE    Display type: wide, standard, ccfl, generic (default: prompt)
  -i NUM     Instrument number (default: prompt)
  -h         Show this help

Examples:
  $(basename "$0")                                        # Interactive menu
  $(basename "$0") create -p ~/display.icc -o DP-1        # Create measurements
  $(basename "$0") compare -s ~/vcgt-validation/2025-03-15 # Compare results
EOF
}

parse_display_type() {
	DISPLAY_TYPE_SET=1
	case "$1" in
	wide) DISPLAY_TYPE="-yw" ;;
	standard) DISPLAY_TYPE="-yl" ;;
	ccfl) DISPLAY_TYPE="-yc" ;;
	generic) DISPLAY_TYPE="" ;;
	*) die "Unknown display type: $1 (use: wide, standard, ccfl, generic)" ;;
	esac
}

check_tool() {
	if ! command -v "$1" >/dev/null 2>&1; then
		die "'$1' not found. Install ArgyllCMS to continue."
	fi
}

check_tools() {
	local missing=0
	for tool in targen dispread dispcal colverify profcheck; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			echo "  $(red "missing"): $tool"
			missing=1
		else
			echo "  $(green "found"):   $tool ($(command -v "$tool"))"
		fi
	done
	if ! command -v wlr-vcgt-loader >/dev/null 2>&1; then
		local local_bin
		local_bin="$(dirname "$(readlink -f "$0")")/build/wlr-vcgt-loader"
		if [ -x "$local_bin" ]; then
			echo "  $(green "found"):   wlr-vcgt-loader ($local_bin)"
		else
			local_bin="$(dirname "$(readlink -f "$0")")/wlr-vcgt-loader"
			if [ -x "$local_bin" ]; then
				echo "  $(green "found"):   wlr-vcgt-loader ($local_bin)"
			else
				echo "  $(yellow "missing"): wlr-vcgt-loader (only needed for Wayland measurement)"
			fi
		fi
	else
		echo "  $(green "found"):   wlr-vcgt-loader ($(command -v wlr-vcgt-loader))"
	fi
	if [ "$missing" -eq 1 ]; then
		die "Required ArgyllCMS tools are missing."
	fi
}

find_wlr_vcgt_loader() {
	if command -v wlr-vcgt-loader >/dev/null 2>&1; then
		echo "wlr-vcgt-loader"
		return
	fi
	local script_dir
	script_dir="$(dirname "$(readlink -f "$0")")"
	if [ -x "$script_dir/build/wlr-vcgt-loader" ]; then
		echo "$script_dir/build/wlr-vcgt-loader"
		return
	fi
	if [ -x "$script_dir/wlr-vcgt-loader" ]; then
		echo "$script_dir/wlr-vcgt-loader"
		return
	fi
	die "wlr-vcgt-loader not found. Build it first: make"
}

pick_display_type() {
	echo
	bold "Select your display backlight type:"
	echo
	echo "  1) LED (wide gamut)    -yw"
	echo "  2) LED (standard)      -yl"
	echo "  3) CCFL                -yc"
	echo "  4) Generic / unknown   (no flag)"
	local choice
	printf 'Choice [1]: '
	read -r choice
	choice="${choice:-1}"
	case "$choice" in
	1) DISPLAY_TYPE="-yw" ;;
	2) DISPLAY_TYPE="-yl" ;;
	3) DISPLAY_TYPE="-yc" ;;
	4) DISPLAY_TYPE="" ;;
	*) DISPLAY_TYPE="-yw" ;;
	esac
}

pick_instrument() {
	echo
	bold "Detecting instruments..."
	echo
	# spotread -? lists instruments but also exits nonzero; just show guidance
	echo "  Use -d1 for the first (usually only) colorimeter."
	echo "  If you have multiple instruments, specify the number."
	ask "Instrument number" INSTRUMENT "1"
}

# --- Session management ---

init_session() {
	local date_stamp
	date_stamp="$(date +%Y-%m-%d_%H%M%S)"
	SESSION_DIR="$VALIDATION_DIR/$date_stamp"
	mkdir -p "$SESSION_DIR"
	echo
	echo "Session directory: $(bold "$SESSION_DIR")"
}

save_session_config() {
	cat >"$SESSION_DIR/session.conf" <<-EOF
		ICC_PROFILE="$ICC_PROFILE"
		OUTPUT_NAME="$OUTPUT_NAME"
		DISPLAY_TYPE="$DISPLAY_TYPE"
		INSTRUMENT="$INSTRUMENT"
		PATCH_POS="$PATCH_POS"
		PATCH_COUNT="$PATCH_COUNT"
	EOF
}

load_session_config() {
	[ -f "$SESSION_DIR/session.conf" ] || return 0
	while IFS='=' read -r key val; do
		# Strip leading/trailing whitespace
		key="${key#"${key%%[![:space:]]*}"}"
		val="${val#"${val%%[![:space:]]*}"}"
		# Strip surrounding quotes
		val="${val#\"}"
		val="${val%\"}"
		[ -z "$key" ] && continue
		case "$key" in
		ICC_PROFILE | OUTPUT_NAME | DISPLAY_TYPE | INSTRUMENT | PATCH_POS | PATCH_COUNT)
			printf -v "$key" '%s' "$val"
			;;
		esac
	done <"$SESSION_DIR/session.conf"
}

# --- Steps ---

step_generate_chart() {
	echo
	bold "=== Generate Test Chart ==="
	echo
	echo

	local ti1="$SESSION_DIR/validation.ti1"
	if [ -f "$ti1" ]; then
		echo "Test chart already exists: $ti1"
		if ! ask_yn "Regenerate?"; then
			return
		fi
	fi

	echo "Generating $PATCH_COUNT-patch test chart with extra gray-axis patches..."
	(cd "$SESSION_DIR" && targen -d3 -G -f "$PATCH_COUNT" validation)
	echo
	echo "$(green "Created"): $ti1"
}

do_measurement() {
	local label="$1" description="$2" target_file="${3:-}" target_label="${4:-}"
	local ti1="$SESSION_DIR/validation.ti1"
	local base="$SESSION_DIR/$label"

	[ -f "$ti1" ] || die "No test chart found. Run the 'Generate test chart' step first."

	# dispread needs the .ti1 alongside the output base name
	cp "$ti1" "$base.ti1"

	echo
	bold "--- Measuring: $description ---"
	echo
	echo
	echo "  Output file: $base.ti3"
	if [ -n "$target_file" ] && [ -f "$target_file" ]; then
		local target_y
		target_y=$(get_luminance_y "$target_file")
		if [ -n "$target_y" ]; then
			echo "  Target brightness: $target_y cd/m² (from $target_label)"
		fi
	fi
	echo "  Position the colorimeter on your display and press Enter."
	pause

	local type_flag=()
	if [ -n "$DISPLAY_TYPE" ]; then
		type_flag=("$DISPLAY_TYPE")
	fi

	dispread -d"$INSTRUMENT" "${type_flag[@]}" \
		-P "$PATCH_POS" "$base"

	echo
	if [ -f "$base.ti3" ]; then
		echo "$(green "Saved"): $base.ti3"
	else
		echo "$(red "Measurement failed") — no .ti3 file produced."
	fi
}

step_measure_wayland_cal() {
	echo
	bold "=== Measure Wayland Calibrated ==="
	echo
	echo
	echo "This measures the display with VCGT calibration loaded by wlr-vcgt-loader."
	echo

	local loader
	loader="$(find_wlr_vcgt_loader)"

	# Start wlr-vcgt-loader if not already running
	if [ -n "$LOADER_PID" ] && kill -0 "$LOADER_PID" 2>/dev/null; then
		echo "wlr-vcgt-loader is already running (PID $LOADER_PID)."
		if ! ask_yn "Use current instance?"; then
			kill "$LOADER_PID" 2>/dev/null || true
			wait "$LOADER_PID" 2>/dev/null || true
			LOADER_PID=""
		fi
	fi

	if [ -z "$LOADER_PID" ] || ! kill -0 "$LOADER_PID" 2>/dev/null; then
		echo "Starting wlr-vcgt-loader..."
		echo "  Profile: $ICC_PROFILE"
		echo "  Output:  $OUTPUT_NAME"
		"$loader" -p "$ICC_PROFILE" -o "$OUTPUT_NAME" &
		LOADER_PID=$!

		# Wait for loader to start (~1 second: 10 ticks x 0.1s each)
		local wait_ticks=0
		while [ "$wait_ticks" -lt 10 ]; do
			if ! kill -0 "$LOADER_PID" 2>/dev/null; then
				die "wlr-vcgt-loader failed to start. Check the profile and output name."
			fi
			sleep 0.1
			wait_ticks=$((wait_ticks + 1))
		done
		echo "$(green "VCGT loaded.") (PID $LOADER_PID)"
	fi

	step_brightness_check "$SESSION_DIR/x11-cal.ti3" "X11"

	do_measurement "wayland-cal" "Wayland calibrated (wlr-vcgt-loader)" \
		"$SESSION_DIR/x11-cal.ti3" "X11"
}

step_measure_x11_cal() {
	echo
	bold "=== Measure X11 Calibrated ==="
	echo
	echo
	echo "This measures the display with VCGT calibration loaded by dispwin on X11."
	echo "Run this step from an X11 session (not Wayland)."
	echo

	if [ -n "${WAYLAND_DISPLAY:-}" ]; then
		echo "$(yellow "Warning"): WAYLAND_DISPLAY is set — you appear to be on Wayland."
		echo "X11 gamma loading with dispwin requires a native X11 session."
		if ! ask_yn "Continue anyway?"; then
			return
		fi
	fi

	check_tool dispwin

	echo "Loading VCGT into X11 gamma ramp with dispwin..."
	dispwin "$ICC_PROFILE"
	green "VCGT loaded via dispwin."
	echo

	step_brightness_check "$SESSION_DIR/wayland-cal.ti3" "Wayland"

	do_measurement "x11-cal" "X11 calibrated (dispwin)" \
		"$SESSION_DIR/wayland-cal.ti3" "Wayland"
}

step_compare() {
	echo
	bold "=== Compare Results ==="
	echo
	echo
	echo "Available .ti3 files in this session:"
	echo

	local ti3_files=()
	local i=0
	for f in "$SESSION_DIR"/*.ti3; do
		[ -f "$f" ] || continue
		i=$((i + 1))
		ti3_files+=("$f")
		echo "  $i) $(basename "$f")"
	done

	if [ "$i" -lt 2 ]; then
		echo
		yellow "Need at least 2 measurement files to compare."
		echo
		echo "Run more measurement steps first."
		return
	fi

	echo
	bold "Select comparisons to run:"
	echo
	echo

	# Auto-detect available comparisons
	local wl_cal="$SESSION_DIR/wayland-cal.ti3"
	local x11_cal="$SESSION_DIR/x11-cal.ti3"

	local ran_comparison=0
	local cv_output

	if [ -f "$wl_cal" ] && [ -f "$x11_cal" ]; then
		bold "--- Wayland vs. X11 (both calibrated) ---"
		echo
		echo "  This is the key test. Low delta-E means wlr-vcgt-loader matches dispwin."
		echo
		cv_output=$(colverify "$wl_cal" "$x11_cal" 2>&1) || true
		echo "$cv_output" | tee "$SESSION_DIR/compare-wayland-vs-x11.txt"
		interpret_colverify "$cv_output"
		compare_brightness "$wl_cal" "$x11_cal" "Wayland" "X11"
		echo
		echo "$(green "Saved"): $SESSION_DIR/compare-wayland-vs-x11.txt"
		echo
		ran_comparison=1
	fi

	if [ -f "$wl_cal" ] && [ -f "$ICC_PROFILE" ]; then
		bold "--- Wayland calibrated vs. ICC profile ---"
		echo
		echo "  Checks how well the calibrated display matches the profile predictions."
		echo
		if profcheck "$wl_cal" "$ICC_PROFILE" >"$SESSION_DIR/profcheck-wayland.txt" 2>&1; then
			cat "$SESSION_DIR/profcheck-wayland.txt"
		else
			echo "  profcheck exited with an error (this is normal if the .ti3"
			echo "  patch set doesn't match the profile's test data)."
			cat "$SESSION_DIR/profcheck-wayland.txt"
		fi
		interpret_profcheck "$(cat "$SESSION_DIR/profcheck-wayland.txt")" "Wayland"
		echo
		echo "$(green "Saved"): $SESSION_DIR/profcheck-wayland.txt"
		echo
		ran_comparison=1
	fi

	if [ -f "$x11_cal" ] && [ -f "$ICC_PROFILE" ]; then
		bold "--- X11 calibrated vs. ICC profile ---"
		echo
		echo
		if profcheck "$x11_cal" "$ICC_PROFILE" >"$SESSION_DIR/profcheck-x11.txt" 2>&1; then
			cat "$SESSION_DIR/profcheck-x11.txt"
		else
			echo "  profcheck exited with an error."
			cat "$SESSION_DIR/profcheck-x11.txt"
		fi
		interpret_profcheck "$(cat "$SESSION_DIR/profcheck-x11.txt")" "X11"
		echo
		echo "$(green "Saved"): $SESSION_DIR/profcheck-x11.txt"
		echo
		ran_comparison=1
	fi

	if [ "$ran_comparison" -eq 0 ]; then
		yellow "No recognized file pairs found for automatic comparison."
		echo
		echo "You can run colverify manually:"
		echo "  colverify <file1>.ti3 <file2>.ti3"
	fi
}

step_cleanup() {
	echo
	bold "=== Cleanup ==="
	echo
	echo
	if [ -n "$LOADER_PID" ] && kill -0 "$LOADER_PID" 2>/dev/null; then
		echo "Killing wlr-vcgt-loader (PID $LOADER_PID)..."
		kill "$LOADER_PID" 2>/dev/null || true
		wait "$LOADER_PID" 2>/dev/null || true
		LOADER_PID=""
		echo "Gamma restored to default."
	else
		echo "No wlr-vcgt-loader process running."
	fi
	echo
	echo "Session files saved in: $(bold "$SESSION_DIR")"
	echo
	ls -la "$SESSION_DIR"/ 2>/dev/null || true
}

# --- Resume support ---

pick_session() {
	bold "Existing sessions in $VALIDATION_DIR:"
	echo
	echo

	local sessions=()
	local i=0
	for d in "$VALIDATION_DIR"/*/; do
		[ -d "$d" ] || continue
		i=$((i + 1))
		sessions+=("$d")
		local files=0 ti3
		for ti3 in "$d"*.ti3; do
			[ -f "$ti3" ] || continue
			files=$((files + 1))
		done
		echo "  $i) $(basename "$d")  ($files .ti3 files)"
	done

	if [ "$i" -eq 0 ]; then
		return 1
	fi

	echo
	local choice
	printf '%s' "$(bold "Session number (or Enter for new): ")"
	read -r choice

	if [ -z "$choice" ]; then
		return 1
	fi

	if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$i" ]; then
		SESSION_DIR="${sessions[$((choice - 1))]}"
		SESSION_DIR="${SESSION_DIR%/}"
		load_session_config
		return 0
	fi

	return 1
}

# --- Main menu ---

main_menu() {
	while true; do
		echo
		bold "========================================="
		echo
		bold " VCGT Calibration Validation"
		echo
		bold "========================================="
		echo
		echo
		echo "  Session: $(bold "$SESSION_DIR")"
		echo "  Profile: $ICC_PROFILE"
		echo "  Output:  $OUTPUT_NAME"
		echo
		echo "  1) Generate test chart"
		echo "  2) Measure Wayland calibrated"
		echo "  3) Measure X11 calibrated"
		echo "  4) Compare results"
		echo "  5) Cleanup and show files"
		echo "  q) Quit"
		echo
		local choice
		printf '%s' "$(bold "Choice: ")"
		read -r choice

		case "$choice" in
		1) step_generate_chart ;;
		2) step_measure_wayland_cal ;;
		3) step_measure_x11_cal ;;
		4) step_compare ;;
		5) step_cleanup ;;
		q | Q)
			step_cleanup
			exit 0
			;;
		*) echo "Invalid choice." ;;
		esac
	done
}

# --- Command: create ---

setup_params() {
	# Prompt for any required parameters not provided via CLI flags
	if [ -z "$ICC_PROFILE" ]; then
		ask "Path to ICC profile" ICC_PROFILE ""
	fi
	[ -f "$ICC_PROFILE" ] || die "File not found: $ICC_PROFILE"

	if [ -z "$OUTPUT_NAME" ]; then
		ask "Wayland output name (e.g. DP-1)" OUTPUT_NAME ""
	fi

	if [ "$DISPLAY_TYPE_SET" -eq 0 ]; then
		pick_display_type
	fi

	if [ -z "$INSTRUMENT" ]; then
		pick_instrument
	fi
}

cmd_create() {
	echo
	bold "VCGT Calibration — Create Measurements"
	echo
	bold "======================================="
	echo
	echo

	bold "Checking tools..."
	echo
	check_tools
	echo

	setup_params

	# Session directory
	if [ -z "$SESSION_DIR" ]; then
		init_session
	else
		mkdir -p "$SESSION_DIR"
		echo
		echo "Session directory: $(bold "$SESSION_DIR")"
	fi

	save_session_config

	# Generate chart
	step_generate_chart

	# Measurements — ask for each
	echo
	if ask_yn "Measure Wayland calibrated?"; then
		step_measure_wayland_cal
	fi

	echo
	if ask_yn "Measure X11 calibrated?" "n"; then
		step_measure_x11_cal
	fi

	# Summary
	echo
	echo "$(green "Done.") Session files:"
	echo
	ls -la "$SESSION_DIR"/*.ti3 2>/dev/null || echo "  (no .ti3 files yet)"
	echo
	echo "Run '$(basename "$0") compare -s $SESSION_DIR' to compare results."
}

# --- Command: compare ---

cmd_compare() {
	echo
	bold "VCGT Calibration — Compare Results"
	echo
	bold "==================================="
	echo
	echo

	bold "Checking tools..."
	echo
	check_tools
	echo

	# Session directory
	if [ -z "$SESSION_DIR" ]; then
		if [ -d "$VALIDATION_DIR" ]; then
			if ! pick_session; then
				die "No session selected. Use -s to specify a session directory."
			fi
		else
			die "No sessions found in $VALIDATION_DIR. Run 'create' first."
		fi
	else
		[ -d "$SESSION_DIR" ] || die "Session directory not found: $SESSION_DIR"
		load_session_config
	fi

	echo "Session: $(bold "$SESSION_DIR")"

	# Load ICC profile from session config if not provided via CLI
	if [ -z "$ICC_PROFILE" ] && [ -f "$SESSION_DIR/session.conf" ]; then
		load_session_config
	fi

	if [ -n "$ICC_PROFILE" ]; then
		echo "Profile: $ICC_PROFILE"
	else
		yellow "No ICC profile set — profcheck comparisons will be skipped."
		echo
	fi

	step_compare
}

# --- Command: interactive (default) ---

cmd_interactive() {
	echo
	bold "VCGT Calibration Validation Script"
	echo
	bold "==================================="
	echo
	echo
	echo "This script walks you through measuring and comparing display"
	echo "calibration on Wayland and X11 using a hardware colorimeter."
	echo

	bold "Checking tools..."
	echo
	check_tools
	echo

	# Session: new or resume
	if [ -d "$VALIDATION_DIR" ] && ls "$VALIDATION_DIR"/*/session.conf >/dev/null 2>&1; then
		if ask_yn "Resume an existing session?" "n"; then
			if pick_session; then
				echo
				echo "Resumed session: $(bold "$SESSION_DIR")"
				# Session config provides defaults; let user override below
			fi
		fi
	fi

	if [ -z "$SESSION_DIR" ]; then
		init_session
	fi

	# Gather parameters (use session config as defaults if resuming)
	ask "Path to ICC profile" ICC_PROFILE "${ICC_PROFILE:-}"
	[ -f "$ICC_PROFILE" ] || die "File not found: $ICC_PROFILE"

	ask "Wayland output name (e.g. DP-1)" OUTPUT_NAME "${OUTPUT_NAME:-}"

	pick_display_type
	pick_instrument

	echo
	ask "Patch window position (x,y,scale)" PATCH_POS "${PATCH_POS:-0.5,0.5,1.0}"

	save_session_config

	echo
	green "Configuration saved."
	echo

	main_menu
}

# --- Entry point ---

main() {
	local command=""

	# Parse command (first non-option argument)
	if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
		command="$1"
		shift
	fi

	# Parse options
	while getopts ":p:o:s:n:d:i:h" opt; do
		case "$opt" in
		p) ICC_PROFILE="$OPTARG" ;;
		o) OUTPUT_NAME="$OPTARG" ;;
		s) SESSION_DIR="$OPTARG" ;;
		n) PATCH_COUNT="$OPTARG" ;;
		d) parse_display_type "$OPTARG" ;;
		i) INSTRUMENT="$OPTARG" ;;
		h)
			usage
			exit 0
			;;
		:) die "Option -$OPTARG requires an argument. Use -h for help." ;;
		\?) die "Unknown option: -$OPTARG. Use -h for help." ;;
		esac
	done

	case "$command" in
	create) cmd_create ;;
	compare) cmd_compare ;;
	"") cmd_interactive ;;
	*) die "Unknown command: $command. Use -h for help." ;;
	esac
}

main "$@"
