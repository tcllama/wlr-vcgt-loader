#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cmocka.h>
#include <lcms2.h>

#include "wlr_vcgt_loader_internal.h"

static void free_curves(cmsToneCurve **curves) {
	if (!curves) {
		return;
	}

	for (int i = 0; i < 3; i++) {
		if (curves[i]) {
			cmsFreeToneCurve(curves[i]);
		}
	}

	free(curves);
}

static int make_temp_profile_path(char *path, size_t path_size) {
	(void)path_size;
	strcpy(path, "/tmp/wlr-vcgt-loader-test-XXXXXX");
	int fd = mkstemp(path);
	if (fd < 0) {
		return -1;
	}
	close(fd);
	unlink(path);
	return 0;
}

static int write_profile(const char *path, bool with_vcgt) {
	cmsHPROFILE profile = cmsCreate_sRGBProfile();
	if (!profile) {
		return -1;
	}

	int rc = -1;
	cmsToneCurve *curves[3] = { NULL, NULL, NULL };

	if (with_vcgt) {
		curves[0] = cmsBuildGamma(NULL, 1.0);
		if (!curves[0]) {
			goto cleanup;
		}

		curves[1] = cmsDupToneCurve(curves[0]);
		curves[2] = cmsDupToneCurve(curves[0]);
		if (!curves[1] || !curves[2]) {
			goto cleanup;
		}

		if (!cmsWriteTag(profile, cmsSigVcgtTag, curves)) {
			goto cleanup;
		}
	}

	if (!cmsSaveProfileToFile(profile, path)) {
		goto cleanup;
	}

	rc = 0;

cleanup:
	for (int i = 0; i < 3; i++) {
		if (curves[i]) {
			cmsFreeToneCurve(curves[i]);
		}
	}
	cmsCloseProfile(profile);
	return rc;
}

static int run_command_capture(const char *command, char *output, size_t output_size) {
	FILE *pipe = popen(command, "r");
	if (!pipe) {
		return -1;
	}

	size_t used = 0;
	output[0] = '\0';
	while (used + 1 < output_size) {
		size_t nread = fread(output + used, 1, output_size - used - 1, pipe);
		used += nread;
		if (nread == 0) {
			break;
		}
	}
	output[used] = '\0';

	int status = pclose(pipe);
	if (status == -1) {
		return -1;
	}

	if (WIFEXITED(status)) {
		return WEXITSTATUS(status);
	}

	return 128;
}

static void test_float_to_u16_clamps_and_rounds(void **state) {
	(void)state;

	assert_int_equal(float_to_u16(-1.0), 0);
	assert_int_equal(float_to_u16(0.0), 0);
	assert_int_equal(float_to_u16(0.5), 32768);
	assert_int_equal(float_to_u16(1.0), 65535);
	assert_int_equal(float_to_u16(2.0), 65535);
}

static void test_generate_gamma_table_identity_curve(void **state) {
	(void)state;

	cmsToneCurve *curves[3] = {
		cmsBuildGamma(NULL, 1.0),
		cmsBuildGamma(NULL, 1.0),
		cmsBuildGamma(NULL, 1.0),
	};
	assert_non_null(curves[0]);
	assert_non_null(curves[1]);
	assert_non_null(curves[2]);

	uint16_t *table = generate_gamma_table(5, curves);
	assert_non_null(table);

	assert_int_equal(table[0], 0);
	assert_int_equal(table[1], 16384);
	assert_int_equal(table[2], 32768);
	assert_int_equal(table[3], 49151);
	assert_int_equal(table[4], 65535);

	assert_int_equal(table[5], 0);
	assert_int_equal(table[9], 65535);
	assert_int_equal(table[10], 0);
	assert_int_equal(table[14], 65535);

	for (size_t channel = 0; channel < 3; channel++) {
		for (size_t i = 1; i < 5; i++) {
			assert_true(table[channel * 5 + i] >= table[channel * 5 + i - 1]);
		}
	}

	free(table);
	for (int i = 0; i < 3; i++) {
		cmsFreeToneCurve(curves[i]);
	}
}

static void test_load_icc_vcgt_reads_valid_profile(void **state) {
	(void)state;

	char path[] = "/tmp/wlr-vcgt-loader-test-XXXXXX";
	assert_int_equal(make_temp_profile_path(path, sizeof(path)), 0);
	assert_int_equal(write_profile(path, true), 0);

	cmsHPROFILE profile = NULL;
	cmsToneCurve **curves = load_icc_vcgt(path, &profile);
	assert_non_null(curves);
	assert_non_null(profile);
	assert_non_null(curves[0]);
	assert_non_null(curves[1]);
	assert_non_null(curves[2]);
	assert_int_equal(float_to_u16(cmsEvalToneCurveFloat(curves[0], 0.5)), 32768);

	free_curves(curves);
	cmsCloseProfile(profile);
	unlink(path);
}

static void test_load_icc_vcgt_rejects_profile_without_vcgt(void **state) {
	(void)state;

	char path[] = "/tmp/wlr-vcgt-loader-test-XXXXXX";
	assert_int_equal(make_temp_profile_path(path, sizeof(path)), 0);
	assert_int_equal(write_profile(path, false), 0);

	cmsHPROFILE profile = NULL;
	cmsToneCurve **curves = load_icc_vcgt(path, &profile);
	assert_null(curves);
	assert_null(profile);

	unlink(path);
}

static void test_output_handle_name_matches_target_output(void **state) {
	(void)state;

	struct icc_gamma_state loader_state = {
		.target_output_name = "DP-1",
	};
	struct output_context ctx = {
		.state = &loader_state,
		.wl_name = 42,
	};
	struct wl_output *output = (struct wl_output *)0x1234;

	output_handle_name(&ctx, output, "DP-1");

	assert_true(loader_state.output_matched);
	assert_ptr_equal(loader_state.output, output);
	assert_int_equal(loader_state.output_wl_name, 42);
	assert_ptr_equal(loader_state.matched_ctx, &ctx);
	assert_true(ctx.matched);
}

static void test_output_handle_name_ignores_non_matching_output(void **state) {
	(void)state;

	struct icc_gamma_state loader_state = {
		.target_output_name = "DP-1",
	};
	struct output_context ctx = {
		.state = &loader_state,
		.wl_name = 7,
	};

	output_handle_name(&ctx, (struct wl_output *)0x1234, "HDMI-A-1");

	assert_false(loader_state.output_matched);
	assert_null(loader_state.output);
	assert_null(loader_state.matched_ctx);
	assert_false(ctx.matched);
}

static void test_gamma_control_callbacks_update_state(void **state) {
	(void)state;

	struct icc_gamma_state loader_state = {
		.running = true,
	};

	gamma_control_handle_gamma_size(&loader_state, NULL, 256);
	assert_true(loader_state.gamma_size_received);
	assert_int_equal(loader_state.gamma_size, 256);

	gamma_control_handle_failed(&loader_state, NULL);
	assert_true(loader_state.failed);
	assert_false(loader_state.running);
}

static void test_handle_global_remove_stops_matched_output(void **state) {
	(void)state;

	struct icc_gamma_state loader_state = {
		.output_matched = true,
		.output_wl_name = 9,
		.running = true,
	};

	handle_global_remove(&loader_state, NULL, 8);
	assert_true(loader_state.running);

	handle_global_remove(&loader_state, NULL, 9);
	assert_false(loader_state.running);
}

static void test_cli_help_succeeds(void **state) {
	(void)state;

	char output[4096];
	int status = run_command_capture("./wlr-vcgt-loader --help 2>&1", output, sizeof(output));

	assert_int_equal(status, 0);
	assert_non_null(strstr(output, "Usage: wlr-vcgt-loader"));
	assert_non_null(strstr(output, "--profile"));
	assert_non_null(strstr(output, "--output"));
}

static void test_cli_missing_required_args_fails(void **state) {
	(void)state;

	char output[4096];
	int status = run_command_capture("./wlr-vcgt-loader 2>&1", output, sizeof(output));

	assert_true(status != 0);
	assert_non_null(strstr(output, "--profile and --output are required"));
	assert_non_null(strstr(output, "Usage: wlr-vcgt-loader"));
}

static void test_cli_rejects_missing_profile_path(void **state) {
	(void)state;

	char output[4096];
	int status = run_command_capture("./wlr-vcgt-loader -p /tmp/does-not-exist.icc -o DP-1 2>&1", output, sizeof(output));

	assert_true(status != 0);
	assert_non_null(strstr(output, "Error: failed to open ICC profile"));
	assert_non_null(strstr(output, "/tmp/does-not-exist.icc"));
}

static void test_cli_rejects_profile_without_vcgt(void **state) {
	(void)state;

	char path[] = "/tmp/wlr-vcgt-loader-test-XXXXXX";
	assert_int_equal(make_temp_profile_path(path, sizeof(path)), 0);
	assert_int_equal(write_profile(path, false), 0);

	char command[512];
	char output[4096];
	snprintf(command, sizeof(command), "./wlr-vcgt-loader -p %s -o DP-1 2>&1", path);
	int status = run_command_capture(command, output, sizeof(output));

	assert_true(status != 0);
	assert_non_null(strstr(output, "Error: ICC profile has no VCGT tag"));
	assert_non_null(strstr(output, path));

	unlink(path);
}

int main(void) {
	const struct CMUnitTest tests[] = {
		cmocka_unit_test(test_float_to_u16_clamps_and_rounds),
		cmocka_unit_test(test_generate_gamma_table_identity_curve),
		cmocka_unit_test(test_load_icc_vcgt_reads_valid_profile),
		cmocka_unit_test(test_load_icc_vcgt_rejects_profile_without_vcgt),
		cmocka_unit_test(test_output_handle_name_matches_target_output),
		cmocka_unit_test(test_output_handle_name_ignores_non_matching_output),
		cmocka_unit_test(test_gamma_control_callbacks_update_state),
		cmocka_unit_test(test_handle_global_remove_stops_matched_output),
		cmocka_unit_test(test_cli_help_succeeds),
		cmocka_unit_test(test_cli_missing_required_args_fails),
		cmocka_unit_test(test_cli_rejects_missing_profile_path),
		cmocka_unit_test(test_cli_rejects_profile_without_vcgt),
	};

	return cmocka_run_group_tests(tests, NULL, NULL);
}
