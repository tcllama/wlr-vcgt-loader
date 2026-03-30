#ifndef WLR_VCGT_LOADER_INTERNAL_H
#define WLR_VCGT_LOADER_INTERNAL_H

#include <stdbool.h>
#include <stdint.h>

#include <lcms2.h>
#include <wayland-client.h>

#include "wlr-gamma-control-unstable-v1-client-protocol.h"

struct icc_gamma_state {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_output *output;
	struct zwlr_gamma_control_manager_v1 *gamma_manager;
	struct zwlr_gamma_control_v1 *gamma_control;
	char *target_output_name;
	char *icc_path;
	struct output_context *matched_ctx;
	uint32_t output_wl_name;
	uint32_t gamma_size;
	bool output_matched;
	bool gamma_size_received;
	bool running;
	bool failed;
};

struct output_context {
	struct icc_gamma_state *state;
	uint32_t wl_name;
	bool matched;
};

uint16_t float_to_u16(cmsFloat32Number v);
cmsToneCurve **load_icc_vcgt(const char *path, cmsHPROFILE *out_profile);
uint16_t *generate_gamma_table(uint32_t gamma_size, cmsToneCurve **vcgt);
void output_handle_name(void *data, struct wl_output *output, const char *name);
void gamma_control_handle_gamma_size(void *data,
	struct zwlr_gamma_control_v1 *control, uint32_t size);
void gamma_control_handle_failed(void *data,
	struct zwlr_gamma_control_v1 *control);
void handle_global_remove(void *data, struct wl_registry *registry,
	uint32_t name);

#endif
