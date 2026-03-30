#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <poll.h>
#include <sys/mman.h>
#include <unistd.h>

#include <lcms2.h>
#include <wayland-client.h>

#include "wlr_vcgt_loader_internal.h"

static void usage(void) {
	fprintf(stderr,
		"Usage: wlr-vcgt-loader -p <profile.icc> -o <output-name>\n"
		"\n"
		"Apply ICC profile VCGT calibration curves via wlr-gamma-control.\n"
		"\n"
		"Options:\n"
		"  -p, --profile <path>   Path to ICC profile file (required)\n"
		"  -o, --output <name>    Wayland output name, e.g. DP-1 (required)\n"
		"  -h, --help             Show this help\n"
		"\n"
		"Runs as a persistent process. Kill to restore original gamma.\n");
}

static void parse_args(int argc, char *argv[], struct icc_gamma_state *state) {
	static const struct option long_options[] = {
		{"profile", required_argument, NULL, 'p'},
		{"output",  required_argument, NULL, 'o'},
		{"help",    no_argument,       NULL, 'h'},
		{0, 0, 0, 0},
	};

	int opt;
	while ((opt = getopt_long(argc, argv, "p:o:h", long_options, NULL)) != -1) {
		switch (opt) {
		case 'p':
			state->icc_path = optarg;
			break;
		case 'o':
			state->target_output_name = optarg;
			break;
		case 'h':
			usage();
			exit(EXIT_SUCCESS);
		default:
			usage();
			exit(EXIT_FAILURE);
		}
	}

	if (!state->icc_path || !state->target_output_name) {
		fprintf(stderr, "Error: --profile and --output are required\n\n");
		usage();
		exit(EXIT_FAILURE);
	}
}

/* --- Signal handling --- */

static volatile sig_atomic_t quit_requested;

static void handle_signal(int sig) {
	(void)sig;
	quit_requested = 1;
}

/* --- ICC / VCGT functions --- */

uint16_t float_to_u16(cmsFloat32Number v) {
	long val = lround((double)v * 0xFFFF);
	if (val < 0) val = 0;
	if (val > 0xFFFF) val = 0xFFFF;
	return (uint16_t)val;
}

cmsToneCurve **load_icc_vcgt(const char *path, cmsHPROFILE *out_profile) {
	cmsHPROFILE profile = cmsOpenProfileFromFile(path, "r");
	if (!profile) {
		fprintf(stderr, "Error: failed to open ICC profile: %s\n", path);
		return NULL;
	}

	const cmsToneCurve **vcgt = cmsReadTag(profile, cmsSigVcgtTag);
	if (!vcgt || !vcgt[0]) {
		fprintf(stderr, "Error: ICC profile has no VCGT tag: %s\n", path);
		cmsCloseProfile(profile);
		return NULL;
	}

	cmsToneCurve **curves = calloc(3, sizeof(cmsToneCurve *));
	if (!curves) {
		perror("calloc");
		cmsCloseProfile(profile);
		return NULL;
	}

	curves[0] = cmsDupToneCurve(vcgt[0]);
	curves[1] = cmsDupToneCurve(vcgt[1]);
	curves[2] = cmsDupToneCurve(vcgt[2]);

	if (!curves[0] || !curves[1] || !curves[2]) {
		fprintf(stderr, "Error: failed to duplicate VCGT tone curves\n");
		for (int i = 0; i < 3; i++) {
			if (curves[i])
				cmsFreeToneCurve(curves[i]);
		}
		free(curves);
		cmsCloseProfile(profile);
		return NULL;
	}

	*out_profile = profile;
	return curves;
}

uint16_t *generate_gamma_table(uint32_t gamma_size, cmsToneCurve **vcgt) {
	size_t table_size = (size_t)gamma_size * 3;
	uint16_t *table = calloc(table_size, sizeof(uint16_t));
	if (!table) {
		perror("calloc");
		return NULL;
	}

	uint16_t *r = table;
	uint16_t *g = table + gamma_size;
	uint16_t *b = table + 2 * gamma_size;

	for (uint32_t i = 0; i < gamma_size; i++) {
		cmsFloat32Number in = (cmsFloat32Number)i / (cmsFloat32Number)(gamma_size - 1);
		r[i] = float_to_u16(cmsEvalToneCurveFloat(vcgt[0], in));
		g[i] = float_to_u16(cmsEvalToneCurveFloat(vcgt[1], in));
		b[i] = float_to_u16(cmsEvalToneCurveFloat(vcgt[2], in));
	}

	return table;
}

/* --- Wayland output listener --- */

static void output_handle_geometry(void *data, struct wl_output *output,
		int32_t x, int32_t y, int32_t physical_width, int32_t physical_height,
		int32_t subpixel, const char *make, const char *model,
		int32_t transform) {
	(void)data; (void)output;
	(void)x; (void)y; (void)physical_width; (void)physical_height;
	(void)subpixel; (void)make; (void)model; (void)transform;
}

static void output_handle_mode(void *data, struct wl_output *output,
		uint32_t flags, int32_t width, int32_t height, int32_t refresh) {
	(void)data; (void)output;
	(void)flags; (void)width; (void)height; (void)refresh;
}

static void output_handle_done(void *data, struct wl_output *output) {
	struct output_context *ctx = data;
	if (!ctx->matched) {
		wl_output_release(output);
		free(ctx);
	}
}

static void output_handle_scale(void *data, struct wl_output *output,
		int32_t factor) {
	(void)data; (void)output; (void)factor;
}

void output_handle_name(void *data, struct wl_output *output,
		const char *name) {
	struct output_context *ctx = data;
	struct icc_gamma_state *state = ctx->state;
	if (strcmp(name, state->target_output_name) == 0) {
		state->output = output;
		state->output_wl_name = ctx->wl_name;
		state->output_matched = true;
		state->matched_ctx = ctx;
		ctx->matched = true;
	}
}

static void output_handle_description(void *data, struct wl_output *output,
		const char *description) {
	(void)data; (void)output; (void)description;
}

static const struct wl_output_listener output_listener = {
	.geometry = output_handle_geometry,
	.mode = output_handle_mode,
	.done = output_handle_done,
	.scale = output_handle_scale,
	.name = output_handle_name,
	.description = output_handle_description,
};

/* --- Gamma control listener --- */

void gamma_control_handle_gamma_size(void *data,
		struct zwlr_gamma_control_v1 *control, uint32_t size) {
	(void)control;
	struct icc_gamma_state *state = data;
	state->gamma_size = size;
	state->gamma_size_received = true;
}

void gamma_control_handle_failed(void *data,
		struct zwlr_gamma_control_v1 *control) {
	(void)control;
	struct icc_gamma_state *state = data;
	fprintf(stderr, "Error: gamma control failed (output may not support "
		"gamma tables, or another client has exclusive access)\n");
	state->failed = true;
	state->running = false;
}

static const struct zwlr_gamma_control_v1_listener gamma_control_listener = {
	.gamma_size = gamma_control_handle_gamma_size,
	.failed = gamma_control_handle_failed,
};

/* --- Registry listener --- */

static void handle_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	struct icc_gamma_state *state = data;

	if (strcmp(interface, wl_output_interface.name) == 0) {
		uint32_t bind_ver = version < 4 ? version : 4;
		if (bind_ver < 4) {
			fprintf(stderr, "Warning: wl_output v%u (need v4 for name); "
				"skipping output %u\n", version, name);
			return;
		}
		struct output_context *ctx = calloc(1, sizeof(*ctx));
		if (!ctx) {
			perror("calloc");
			return;
		}
		ctx->state = state;
		ctx->wl_name = name;
		struct wl_output *output = wl_registry_bind(registry, name,
			&wl_output_interface, bind_ver);
		wl_output_add_listener(output, &output_listener, ctx);
	} else if (strcmp(interface,
			zwlr_gamma_control_manager_v1_interface.name) == 0) {
		state->gamma_manager = wl_registry_bind(registry, name,
			&zwlr_gamma_control_manager_v1_interface, 1);
	}
}

void handle_global_remove(void *data, struct wl_registry *registry,
		uint32_t name) {
	(void)registry;
	struct icc_gamma_state *state = data;
	if (state->output_matched && name == state->output_wl_name) {
		state->running = false;
	}
}

static const struct wl_registry_listener registry_listener = {
	.global = handle_global,
	.global_remove = handle_global_remove,
};

/* --- Apply gamma via memfd --- */

static int apply_gamma(struct icc_gamma_state *state, uint16_t *table) {
	size_t table_size = (size_t)state->gamma_size * 3 * sizeof(uint16_t);

	int fd = memfd_create("gamma_table", MFD_CLOEXEC | MFD_ALLOW_SEALING);
	if (fd < 0) {
		perror("memfd_create");
		return -1;
	}

	if (ftruncate(fd, table_size) < 0) {
		perror("ftruncate");
		close(fd);
		return -1;
	}

	void *mapped = mmap(NULL, table_size, PROT_READ | PROT_WRITE,
		MAP_SHARED, fd, 0);
	if (mapped == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return -1;
	}
	memcpy(mapped, table, table_size);
	munmap(mapped, table_size);

	fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL);

	zwlr_gamma_control_v1_set_gamma(state->gamma_control, fd);
	close(fd);
	return 0;
}

/* --- Main --- */

#ifndef WLR_VCGT_LOADER_TESTING
int main(int argc, char *argv[]) {
	struct icc_gamma_state state = {0};
	cmsHPROFILE profile = NULL;
	cmsToneCurve **vcgt = NULL;
	uint16_t *table = NULL;
	int ret = EXIT_FAILURE;

	parse_args(argc, argv, &state);

	/* Load ICC profile and extract VCGT */
	vcgt = load_icc_vcgt(state.icc_path, &profile);
	if (!vcgt) {
		goto cleanup;
	}

	/* Connect to Wayland */
	state.display = wl_display_connect(NULL);
	if (!state.display) {
		fprintf(stderr, "Error: failed to connect to Wayland display. "
			"Check WAYLAND_DISPLAY environment variable.\n");
		goto cleanup;
	}

	state.registry = wl_display_get_registry(state.display);
	wl_registry_add_listener(state.registry, &registry_listener, &state);

	/* First roundtrip: discover globals */
	if (wl_display_roundtrip(state.display) < 0) {
		fprintf(stderr, "Error: Wayland roundtrip failed\n");
		goto cleanup;
	}

	/* Second roundtrip: receive output names */
	if (wl_display_roundtrip(state.display) < 0) {
		fprintf(stderr, "Error: Wayland roundtrip failed\n");
		goto cleanup;
	}

	if (!state.gamma_manager) {
		fprintf(stderr, "Error: compositor does not support "
			"wlr-gamma-control-unstable-v1\n");
		goto cleanup;
	}

	if (!state.output_matched) {
		fprintf(stderr, "Error: output '%s' not found\n",
			state.target_output_name);
		goto cleanup;
	}

	/* Get gamma control for the matched output */
	state.gamma_control = zwlr_gamma_control_manager_v1_get_gamma_control(
		state.gamma_manager, state.output);
	zwlr_gamma_control_v1_add_listener(state.gamma_control,
		&gamma_control_listener, &state);

	/* Third roundtrip: receive gamma_size */
	if (wl_display_roundtrip(state.display) < 0) {
		fprintf(stderr, "Error: Wayland roundtrip failed\n");
		goto cleanup;
	}

	if (state.failed) {
		goto cleanup;
	}

	if (!state.gamma_size_received || state.gamma_size < 2) {
		fprintf(stderr, "Error: did not receive valid gamma size\n");
		goto cleanup;
	}

	fprintf(stderr, "Applying VCGT from %s to output %s (gamma size: %u)\n",
		state.icc_path, state.target_output_name, state.gamma_size);

	/* Generate and apply the gamma LUT */
	table = generate_gamma_table(state.gamma_size, vcgt);
	if (!table) {
		goto cleanup;
	}

	if (apply_gamma(&state, table) < 0) {
		fprintf(stderr, "Error: failed to apply gamma table\n");
		goto cleanup;
	}

	/* Resources no longer needed after applying gamma */
	free(table);
	table = NULL;
	cmsFreeToneCurve(vcgt[0]);
	cmsFreeToneCurve(vcgt[1]);
	cmsFreeToneCurve(vcgt[2]);
	free(vcgt);
	vcgt = NULL;
	cmsCloseProfile(profile);
	profile = NULL;

	/* Register signal handlers for clean shutdown */
	struct sigaction sa = { .sa_handler = handle_signal };
	sigemptyset(&sa.sa_mask);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	/* Event loop: stay alive to keep gamma active.
	 * We use a manual loop with poll() instead of wl_display_dispatch()
	 * because libwayland retries poll() on EINTR, which prevents signal
	 * handlers from interrupting the loop. */
	int wl_fd = wl_display_get_fd(state.display);
	struct pollfd pfd = { .fd = wl_fd, .events = POLLIN };

	state.running = true;
	while (state.running && !quit_requested) {
		while (wl_display_flush(state.display) == -1) {
			if (errno != EAGAIN)
				goto loop_end;
			struct pollfd wpfd = { .fd = wl_fd, .events = POLLOUT };
			if (poll(&wpfd, 1, -1) == -1) {
				if (errno == EINTR)
					continue;
				goto loop_end;
			}
		}

		if (wl_display_prepare_read(state.display) != 0) {
			wl_display_dispatch_pending(state.display);
			continue;
		}

		int pollret = poll(&pfd, 1, -1);
		if (pollret == -1) {
			wl_display_cancel_read(state.display);
			if (errno == EINTR)
				continue;
			break;
		}

		if (wl_display_read_events(state.display) == -1)
			break;

		if (wl_display_dispatch_pending(state.display) == -1)
			break;
	}
loop_end:

	if (!quit_requested && state.running) {
		int err = wl_display_get_error(state.display);
		if (err) {
			fprintf(stderr, "Error: Wayland display error: %s\n",
				strerror(err));
		}
	}

	ret = state.failed ? EXIT_FAILURE : EXIT_SUCCESS;

cleanup:
	free(table);
	free(state.matched_ctx);
	if (vcgt) {
		cmsFreeToneCurve(vcgt[0]);
		cmsFreeToneCurve(vcgt[1]);
		cmsFreeToneCurve(vcgt[2]);
		free(vcgt);
	}
	if (profile) {
		cmsCloseProfile(profile);
	}
	if (state.display) {
		wl_display_disconnect(state.display);
	}
	return ret;
}
#endif
