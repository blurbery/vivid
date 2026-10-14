/*
 * Lucid Engine libdovi C API harness.
 *
 * Feeds every case of a corpus file through every entry point of libdovi's
 * C API, the way a C caller such as FFmpeg or libplacebo would, and prints
 * one summary line per case. Each case runs in its own child process, so a
 * case that aborts (as the unpatched library does on some malformed input)
 * is recorded instead of ending the run.
 *
 *     harness CASES TMPDIR [DUMPDIR]
 *
 * CASES is written by libdovi_test.py: the magic "LDVC1\n", then for each
 * case a big-endian u32 name length, the name, a flags byte, a big-endian
 * u32 data length and the data. Flag 1 writes the case's full dump to
 * DUMPDIR/<index>.txt; flag 2 also calls every entry point with null
 * pointers; flags 4, 8 and 16 skip the first, second and third parser
 * (for valid RPUs given only to the parser that takes their form); flag 32
 * skips the FFmpeg and libplacebo call sequences.
 *
 * Output, one tab-separated line per case:
 *     index  status  hevc-rpu  hevc-nalu  av1-obu  bin-file  ffmpeg  libplacebo
 *     texts  sha256  sha256-without-error-texts  max-rss-kb
 * status is exit:N or signal:N; a case that aborted or crashed exits with
 * 128 + the signal number. Each parser column is ok:<writer failures>,
 * err (the parse failed and every later call returned its error result),
 * inconsistent (the parse failed but a later call did not) or null (the
 * parser returned no object). ffmpeg is the result of FFmpeg's profile 7
 * conversion sequence (convert or skip) and libplacebo that of libplacebo's
 * sequence (meta, header, skip, or dm-null when the display management
 * query returned null after a header that has the data). texts counts the
 * error texts Vivid's patch adds and how many of them break the rules (a
 * line break or a fault substring). The digests cover the full dump, and
 * the dump without its error-text lines.
 *
 * Part of Vivid's Lucid Engine build. Licence: MIT, like libdovi.
 */

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

#include <libdovi/rpu_parser.h>

#define CASE_TIMEOUT_SECONDS 20
#define NO_RESULT "\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-"

typedef DoviRpuOpaque *(*parse_fn)(const uint8_t *, size_t);

static const struct {
    const char *name;
    parse_fn parse;
} parsers[] = {
    {"dovi_parse_rpu", dovi_parse_rpu},
    {"dovi_parse_unspec62_nalu", dovi_parse_unspec62_nalu},
    {"dovi_parse_itu_t35_dovi_metadata_obu", dovi_parse_itu_t35_dovi_metadata_obu},
};
#define NUM_PARSERS (sizeof(parsers) / sizeof(parsers[0]))

/* Conversion modes: the documented 0 to 4 plus out-of-range values. */
static const uint8_t modes[] = {0, 1, 2, 3, 4, 5, 255};

struct verdict {
    bool skipped;         /* not run for this case (flags) */
    bool parsed;          /* first parse returned an RPU without error */
    bool returned_null;   /* a parse returned no object at all */
    int non_error_calls;  /* calls on a failed parse that did not return an error result */
    int writer_failures;  /* writers that returned null after a successful parse */
};

/* ------------------------------------------------------------- dumping */

static void hex(FILE *o, const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++)
        fprintf(o, "%02x", p[i]);
}

static void dump_u16s(FILE *o, const char *k, DoviU16Data d)
{
    fprintf(o, " %s[%zu]=", k, d.len);
    for (size_t i = 0; i < d.len && d.data; i++)
        fprintf(o, "%s%u", i ? "," : "", d.data[i]);
}

static void dump_u64s(FILE *o, const char *k, DoviU64Data d)
{
    fprintf(o, " %s[%zu]=", k, d.len);
    for (size_t i = 0; i < d.len && d.data; i++)
        fprintf(o, "%s%" PRIu64, i ? "," : "", d.data[i]);
}

static void dump_i64s(FILE *o, const char *k, DoviI64Data d)
{
    fprintf(o, " %s[%zu]=", k, d.len);
    for (size_t i = 0; i < d.len && d.data; i++)
        fprintf(o, "%s%" PRId64, i ? "," : "", d.data[i]);
}

static void dump_bytes(FILE *o, const char *k, DoviData d)
{
    fprintf(o, " %s[%zu]=", k, d.len);
    if (d.data)
        hex(o, d.data, d.len);
}

static void dump_u64_2d(FILE *o, const char *k, DoviU64Data2D d)
{
    fprintf(o, " %s{%zu}", k, d.len);
    for (size_t i = 0; i < d.len && d.list; i++)
        dump_u64s(o, "", *d.list[i]);
}

static void dump_i64_2d(FILE *o, const char *k, DoviI64Data2D d)
{
    fprintf(o, " %s{%zu}", k, d.len);
    for (size_t i = 0; i < d.len && d.list; i++)
        dump_i64s(o, "", *d.list[i]);
}

static void dump_header(FILE *o, const DoviRpuDataHeader *h)
{
    fprintf(o, "  header: profile=%u el_type=%s prefix=%u type=%u format=%u vdr_profile=%u "
            "vdr_level=%u seq_info=%d chroma_explicit=%d coef_type=%u log2_denom=%" PRIu64
            " normalized=%u bl_full_range=%d bl_depth=%" PRIu64 " el_depth=%" PRIu64
            " vdr_depth=%" PRIu64 " spatial=%d reserved=%u el_spatial=%d disable_residual=%d"
            " dm_present=%d use_prev=%d prev_id=%" PRIu64 "\n",
            h->guessed_profile, h->el_type ? h->el_type : "(null)", h->rpu_nal_prefix,
            h->rpu_type, h->rpu_format, h->vdr_rpu_profile, h->vdr_rpu_level,
            h->vdr_seq_info_present_flag, h->chroma_resampling_explicit_filter_flag,
            h->coefficient_data_type, h->coefficient_log2_denom, h->vdr_rpu_normalized_idc,
            h->bl_video_full_range_flag, h->bl_bit_depth_minus8, h->el_bit_depth_minus8,
            h->vdr_bit_depth_minus8, h->spatial_resampling_filter_flag, h->reserved_zero_3bits,
            h->el_spatial_resampling_filter_flag, h->disable_residual_flag,
            h->vdr_dm_metadata_present_flag, h->use_prev_vdr_rpu_flag, h->prev_vdr_rpu_id);
}

static void dump_mapping(FILE *o, const DoviRpuDataMapping *m)
{
    fprintf(o, "  mapping: id=%" PRIu64 " color_space=%" PRIu64 " chroma=%" PRIu64
            " x=%" PRIu64 " y=%" PRIu64 " nlq_method=%d nlq_pivots_minus2=%d",
            m->vdr_rpu_id, m->mapping_color_space, m->mapping_chroma_format_idc,
            m->num_x_partitions_minus1, m->num_y_partitions_minus1, m->nlq_method_idc,
            m->nlq_num_pivots_minus2);
    dump_u16s(o, "nlq_pred_pivot", m->nlq_pred_pivot_value);
    fputc('\n', o);
    for (int c = 0; c < DoviNUM_COMPONENTS; c++) {
        const DoviReshapingCurve *cv = &m->curves[c];
        fprintf(o, "  curve%d: pivots_minus2=%" PRIu64 " idc=%u", c, cv->num_pivots_minus2,
                cv->mapping_idc);
        dump_u16s(o, "pivots", cv->pivots);
        if (cv->polynomial) {
            const DoviPolynomialCurve *p = cv->polynomial;
            fprintf(o, " poly:");
            dump_u64s(o, "order", p->poly_order_minus1);
            dump_bytes(o, "interp", p->linear_interp_flag);
            dump_i64_2d(o, "coef_int", p->poly_coef_int);
            dump_u64_2d(o, "coef", p->poly_coef);
        }
        if (cv->mmr) {
            const DoviMMRCurve *r = cv->mmr;
            fprintf(o, " mmr:");
            dump_bytes(o, "order", r->mmr_order_minus1);
            dump_i64s(o, "const_int", r->mmr_constant_int);
            dump_u64s(o, "const", r->mmr_constant);
            fprintf(o, " coef_int{%zu}", r->mmr_coef_int.len);
            for (size_t i = 0; i < r->mmr_coef_int.len && r->mmr_coef_int.list; i++)
                dump_i64_2d(o, "", *r->mmr_coef_int.list[i]);
            fprintf(o, " coef{%zu}", r->mmr_coef.len);
            for (size_t i = 0; i < r->mmr_coef.len && r->mmr_coef.list; i++)
                dump_u64_2d(o, "", *r->mmr_coef.list[i]);
        }
        fputc('\n', o);
    }
    if (m->nlq) {
        const DoviRpuDataNlq *n = m->nlq;
        fprintf(o, "  nlq:");
        for (int c = 0; c < DoviNUM_COMPONENTS; c++)
            fprintf(o, " [%u %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 "]",
                    n->nlq_offset[c], n->vdr_in_max_int[c], n->vdr_in_max[c],
                    n->linear_deadzone_slope_int[c], n->linear_deadzone_slope[c],
                    n->linear_deadzone_threshold_int[c], n->linear_deadzone_threshold[c]);
        fputc('\n', o);
    }
}

static void dump_l8(FILE *o, const DoviExtMetadataBlockLevel8 *b)
{
    fprintf(o, " L8{len=%" PRIu64 " idx=%u %u %u %u %u %u %u %u %u sat=%u,%u,%u,%u,%u,%u"
            " hue=%u,%u,%u,%u,%u,%u}", b->length, b->target_display_index, b->trim_slope,
            b->trim_offset, b->trim_power, b->trim_chroma_weight, b->trim_saturation_gain,
            b->ms_weight, b->target_mid_contrast, b->clip_trim, b->saturation_vector_field0,
            b->saturation_vector_field1, b->saturation_vector_field2, b->saturation_vector_field3,
            b->saturation_vector_field4, b->saturation_vector_field5, b->hue_vector_field0,
            b->hue_vector_field1, b->hue_vector_field2, b->hue_vector_field3,
            b->hue_vector_field4, b->hue_vector_field5);
}

static void dump_l10(FILE *o, const DoviExtMetadataBlockLevel10 *b)
{
    fprintf(o, " L10{len=%" PRIu64 " idx=%u max=%u min=%u prim=%u %u %u %u %u %u %u %u %u}",
            b->length, b->target_display_index, b->target_max_pq, b->target_min_pq,
            b->target_primary_index, b->target_primary_red_x, b->target_primary_red_y,
            b->target_primary_green_x, b->target_primary_green_y, b->target_primary_blue_x,
            b->target_primary_blue_y, b->target_primary_white_x, b->target_primary_white_y);
}

static void dump_dm(FILE *o, const DoviDmData *d)
{
    fprintf(o, "  dm: blocks=%" PRIu64, d->num_ext_blocks);
    if (d->level1)
        fprintf(o, " L1{%u %u %u}", d->level1->min_pq, d->level1->max_pq, d->level1->avg_pq);
    for (size_t i = 0; i < d->level2.len && d->level2.list; i++) {
        const DoviExtMetadataBlockLevel2 *b = d->level2.list[i];
        fprintf(o, " L2{%u %u %u %u %u %u %d}", b->target_max_pq, b->trim_slope, b->trim_offset,
                b->trim_power, b->trim_chroma_weight, b->trim_saturation_gain, b->ms_weight);
    }
    if (d->level3)
        fprintf(o, " L3{%u %u %u}", d->level3->min_pq_offset, d->level3->max_pq_offset,
                d->level3->avg_pq_offset);
    if (d->level4)
        fprintf(o, " L4{%u %u}", d->level4->anchor_pq, d->level4->anchor_power);
    if (d->level5)
        fprintf(o, " L5{%u %u %u %u}", d->level5->active_area_left_offset,
                d->level5->active_area_right_offset, d->level5->active_area_top_offset,
                d->level5->active_area_bottom_offset);
    if (d->level6)
        fprintf(o, " L6{%u %u %u %u}", d->level6->max_display_mastering_luminance,
                d->level6->min_display_mastering_luminance, d->level6->max_content_light_level,
                d->level6->max_frame_average_light_level);
    for (size_t i = 0; i < d->level8.len && d->level8.list; i++)
        dump_l8(o, d->level8.list[i]);
    if (d->level9) {
        const DoviExtMetadataBlockLevel9 *b = d->level9;
        fprintf(o, " L9{len=%" PRIu64 " %u %u %u %u %u %u %u %u %u}", b->length,
                b->source_primary_index, b->source_primary_red_x, b->source_primary_red_y,
                b->source_primary_green_x, b->source_primary_green_y, b->source_primary_blue_x,
                b->source_primary_blue_y, b->source_primary_white_x, b->source_primary_white_y);
    }
    for (size_t i = 0; i < d->level10.len && d->level10.list; i++)
        dump_l10(o, d->level10.list[i]);
    if (d->level11)
        fprintf(o, " L11{%u %u %d %u %u}", d->level11->content_type, d->level11->whitepoint,
                d->level11->reference_mode_flag, d->level11->reserved_byte2,
                d->level11->reserved_byte3);
    if (d->level254)
        fprintf(o, " L254{%u %u}", d->level254->dm_mode, d->level254->dm_version_index);
    if (d->level255)
        fprintf(o, " L255{%u %u %u %u %u %u}", d->level255->dm_run_mode,
                d->level255->dm_run_version, d->level255->dm_debug0, d->level255->dm_debug1,
                d->level255->dm_debug2, d->level255->dm_debug3);
    fputc('\n', o);
}

static void dump_vdr(FILE *o, const DoviVdrDmData *v)
{
    fprintf(o, "  vdr: compressed=%d affected=%" PRIu64 " current=%" PRIu64 " refresh=%" PRIu64
            " ycc=%d,%d,%d,%d,%d,%d,%d,%d,%d off=%u,%u,%u lms=%d,%d,%d,%d,%d,%d,%d,%d,%d"
            " eotf=%u,%u,%u,%u signal=%u,%u,%u,%u source=%u,%u,%u\n",
            v->compressed, v->affected_dm_metadata_id, v->current_dm_metadata_id,
            v->scene_refresh_flag, v->ycc_to_rgb_coef0, v->ycc_to_rgb_coef1, v->ycc_to_rgb_coef2,
            v->ycc_to_rgb_coef3, v->ycc_to_rgb_coef4, v->ycc_to_rgb_coef5, v->ycc_to_rgb_coef6,
            v->ycc_to_rgb_coef7, v->ycc_to_rgb_coef8, v->ycc_to_rgb_offset0,
            v->ycc_to_rgb_offset1, v->ycc_to_rgb_offset2, v->rgb_to_lms_coef0,
            v->rgb_to_lms_coef1, v->rgb_to_lms_coef2, v->rgb_to_lms_coef3, v->rgb_to_lms_coef4,
            v->rgb_to_lms_coef5, v->rgb_to_lms_coef6, v->rgb_to_lms_coef7, v->rgb_to_lms_coef8,
            v->signal_eotf, v->signal_eotf_param0, v->signal_eotf_param1, v->signal_eotf_param2,
            v->signal_bit_depth, v->signal_color_space, v->signal_chroma_format,
            v->signal_full_range_flag, v->source_min_pq, v->source_max_pq, v->source_diagonal);
    dump_dm(o, &v->dm_data);
}

/* ------------------------------------------------------------ exercise */

/* Substrings Vivid treats as faults when they reach its logs (spec 2.8). An
 * error text Vivid's libdovi patch adds may contain none of them. */
static const char *const fault_substrings[] = {
    "Too many packets", "queue overflow", "EOF", "End of file", "timed out",
    "Connection reset", "Error decoding", "Invalid data",
};
static int patch_texts;      /* error texts the patch added */
static int bad_patch_texts;  /* ... with a line break or a fault substring */
static int header_rule;      /* headers with the data flag but no display management data */

/* Prints an error text on one line (line breaks escaped), so the dump
 * digest without error texts can drop exactly these lines. */
static void print_error(FILE *o, const char *what, const char *e)
{
    fprintf(o, "  %s error: ", what);
    if (!e) {
        fputs("(none)\n", o);
        return;
    }
    if (strstr(e, "than the RPU can hold") || strstr(e, "too large to write") ||
        strstr(e, "panic caught at the C API boundary")) {
        bool bad = strchr(e, '\n') || strchr(e, '\r');
        for (size_t i = 0; i < sizeof(fault_substrings) / sizeof(fault_substrings[0]); i++)
            bad = bad || strstr(e, fault_substrings[i]);
        patch_texts++;
        bad_patch_texts += bad;
    }
    for (const char *p = e; *p; p++) {
        if (*p == '\n')
            fputs("\\n", o);
        else if (*p == '\\')
            fputs("\\\\", o);
        else
            fputc(*p, o);
    }
    fputc('\n', o);
}

static void dump_error(FILE *o, const char *what, const DoviRpuOpaque *rpu)
{
    print_error(o, what, dovi_rpu_get_error(rpu));
}

/* FFmpeg's profile 7 conversion (spec 5.6): parse, check the error,
 * convert with mode 2, write, free. Returns convert or skip. */
static const char *ffmpeg_sequence(FILE *o, const uint8_t *buf, size_t len)
{
    const char *result = "skip";
    fprintf(o, "ffmpeg sequence\n");
    DoviRpuOpaque *rpu = dovi_parse_unspec62_nalu(buf, len);
    if (!rpu)
        return "null";
    const char *e = dovi_rpu_get_error(rpu);
    if (e) {
        print_error(o, "parse", e);
    } else if (dovi_convert_rpu_with_mode(rpu, 2) != 0) {
        print_error(o, "convert", dovi_rpu_get_error(rpu));
    } else {
        const DoviData *data = dovi_write_unspec62_nalu(rpu);
        if (data) {
            fprintf(o, "  converted: ");
            hex(o, data->data, data->len);
            fputc('\n', o);
            result = "convert";
        } else {
            print_error(o, "write", dovi_rpu_get_error(rpu));
        }
        dovi_data_free(data);
    }
    dovi_rpu_free(rpu);
    return result;
}

/* libplacebo's pl_hdr_metadata_from_dovi_rpu: parse, the header query and,
 * when the header says display management data is present, that query,
 * whose result libplacebo reads without a null check; then the frees.
 * Returns meta, header (no display management data), skip or dm-null. */
static const char *placebo_sequence(FILE *o, const uint8_t *buf, size_t len)
{
    const char *result = "skip";
    fprintf(o, "libplacebo sequence\n");
    DoviRpuOpaque *rpu = dovi_parse_unspec62_nalu(buf, len);
    const DoviRpuDataHeader *header = dovi_rpu_get_header(rpu);
    if (header && header->vdr_dm_metadata_present_flag) {
        const DoviVdrDmData *dm = dovi_rpu_get_vdr_dm_data(rpu);
        if (!dm) {
            fprintf(o, "  display management data: null after a header that has it\n");
            result = "dm-null";
        } else {
            const DoviDmData *d = &dm->dm_data;
            fprintf(o, "  source pq %u..%u", dm->source_min_pq, dm->source_max_pq);
            if (d->level1)
                fprintf(o, " L1 %u %u %u", d->level1->min_pq, d->level1->max_pq, d->level1->avg_pq);
            if (d->level6)
                fprintf(o, " L6 %u %u %u %u", d->level6->max_display_mastering_luminance,
                        d->level6->min_display_mastering_luminance,
                        d->level6->max_content_light_level, d->level6->max_frame_average_light_level);
            fputc('\n', o);
            result = "meta";
        }
        dovi_rpu_free_vdr_dm_data(dm);
    } else if (header) {
        result = "header";
    }
    dovi_rpu_free_header(header);
    dovi_rpu_free(rpu);
    return result;
}

/* Every getter and writer on one RPU object. */
static void dump_rpu(FILE *o, DoviRpuOpaque *rpu, struct verdict *v, bool failed)
{
    static const struct {
        const char *name;
        const DoviData *(*write)(DoviRpuOpaque *);
    } writers[] = {
        {"write_rpu", dovi_write_rpu},
        {"write_unspec62_nalu", dovi_write_unspec62_nalu},
        {"write_av1_payload", dovi_write_av1_rpu_metadata_obu_t35_payload},
        {"write_av1_complete", dovi_write_av1_rpu_metadata_obu_t35_complete},
    };

    dump_error(o, "state", rpu);

    /* A header that says display management data is present while that
     * query returns null is what 5.13 rule 2 turns into a null header; it is
     * printed as dm-missing, which the results digest equates with null. */
    const DoviRpuDataHeader *h = dovi_rpu_get_header(rpu);
    const DoviVdrDmData *dm_check = dovi_rpu_get_vdr_dm_data(rpu);
    if (h && h->vdr_dm_metadata_present_flag && !dm_check) {
        fprintf(o, "  header: dm-missing ");
        dump_header(o, h);
        header_rule++;
        v->non_error_calls += failed;
    } else if (h) {
        dump_header(o, h);
        v->non_error_calls += failed;
    } else {
        fprintf(o, "  header: null\n");
    }
    dovi_rpu_free_vdr_dm_data(dm_check);
    dovi_rpu_free_header(h);

    const DoviRpuDataMapping *m = dovi_rpu_get_data_mapping(rpu);
    if (m) {
        dump_mapping(o, m);
        v->non_error_calls += failed;
    } else {
        fprintf(o, "  mapping: null\n");
    }
    dovi_rpu_free_data_mapping(m);

    const DoviVdrDmData *d = dovi_rpu_get_vdr_dm_data(rpu);
    if (d) {
        dump_vdr(o, d);
        v->non_error_calls += failed;
    } else {
        fprintf(o, "  vdr: null\n");
    }
    dovi_rpu_free_vdr_dm_data(d);

    for (size_t i = 0; i < sizeof(writers) / sizeof(writers[0]); i++) {
        const DoviData *data = writers[i].write(rpu);
        fprintf(o, "  %s: ", writers[i].name);
        if (data) {
            hex(o, data->data, data->len);
            fputc('\n', o);
            v->non_error_calls += failed;
        } else {
            fprintf(o, "null\n");
            dump_error(o, writers[i].name, rpu);
        }
        dovi_data_free(data);
    }
}

static void exercise_parser(FILE *o, size_t pi, const uint8_t *buf, size_t len, struct verdict *v)
{
    parse_fn parse = parsers[pi].parse;

    fprintf(o, "%s\n", parsers[pi].name);
    DoviRpuOpaque *rpu = parse(buf, len);
    if (!rpu) {
        v->returned_null = true;
        fprintf(o, "  parse: null\n");
        return;
    }
    v->parsed = dovi_rpu_get_error(rpu) == NULL;
    bool failed = !v->parsed;
    dump_rpu(o, rpu, v, failed);
    if (v->parsed) {
        /* Count writer failures on the freshly parsed RPU. */
        const DoviData *(*w[])(DoviRpuOpaque *) = {
            dovi_write_rpu, dovi_write_unspec62_nalu,
            dovi_write_av1_rpu_metadata_obu_t35_payload,
            dovi_write_av1_rpu_metadata_obu_t35_complete,
        };
        for (size_t i = 0; i < 4; i++) {
            const DoviData *data = w[i](rpu);
            v->writer_failures += data == NULL;
            dovi_data_free(data);
        }
    }
    dovi_rpu_free(rpu);

    for (size_t i = 0; i < sizeof(modes); i++) {
        rpu = parse(buf, len);
        if (!rpu) {
            v->returned_null = true;
            continue;
        }
        int ret = dovi_convert_rpu_with_mode(rpu, modes[i]);
        fprintf(o, " convert mode %u: %d\n", modes[i], ret);
        if (failed && ret != -1)
            v->non_error_calls++;
        dump_rpu(o, rpu, v, failed);
        dovi_rpu_free(rpu);
    }

    rpu = parse(buf, len);
    if (rpu) {
        int ret = dovi_rpu_set_active_area_offsets(rpu, 0, 0, 138, 138);
        fprintf(o, " set_active_area_offsets: %d\n", ret);
        if (failed && ret != -1)
            v->non_error_calls++;
        dump_rpu(o, rpu, v, failed);
        dovi_rpu_free(rpu);
    }

    rpu = parse(buf, len);
    if (rpu) {
        int ret = dovi_rpu_remove_mapping(rpu);
        fprintf(o, " remove_mapping: %d\n", ret);
        if (failed && ret != -1)
            v->non_error_calls++;
        dump_rpu(o, rpu, v, failed);
        dovi_rpu_free(rpu);
    }
}

/* dovi_parse_rpu_bin_file on the case written to a file. Returns the
 * number of RPUs, or -1 when the list carries an error. */
static long exercise_bin_file(FILE *o, const char *tmpdir, const uint8_t *buf, size_t len)
{
    char path[4096];
    snprintf(path, sizeof(path), "%s/case-%d.bin", tmpdir, (int)getpid());
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(buf, 1, len, f) != len || fclose(f) != 0) {
        fprintf(stderr, "harness: cannot write %s: %s\n", path, strerror(errno));
        _exit(3);
    }
    const DoviRpuOpaqueList *list = dovi_parse_rpu_bin_file(path);
    unlink(path);
    long result = -1;
    fprintf(o, "dovi_parse_rpu_bin_file\n");
    if (!list) {
        fprintf(o, "  list: null\n");
    } else {
        fprintf(o, "  list: len=%zu\n", list->len);
        print_error(o, "list", list->error);
        if (!list->error)
            result = (long)list->len;
        struct verdict ignored = {0};
        for (size_t i = 0; i < list->len && list->list; i++)
            dump_rpu(o, list->list[i], &ignored, false);
    }
    dovi_rpu_list_free(list);
    return result;
}

/* Every entry point with null pointers. */
static void exercise_null(FILE *o, struct verdict v[NUM_PARSERS])
{
    static const uint8_t nothing[1];
    fprintf(o, "null pointers\n");
    for (size_t i = 0; i < NUM_PARSERS; i++) {
        for (size_t n = 0; n < 2; n++) {
            DoviRpuOpaque *rpu = parsers[i].parse(NULL, n ? 64 : 0);
            if (!rpu) {
                v[i].returned_null = true;
                continue;
            }
            const char *e = dovi_rpu_get_error(rpu);
            char what[96];
            snprintf(what, sizeof(what), "%s(NULL, %d)", parsers[i].name, n ? 64 : 0);
            print_error(o, what, e);
            if (!e)
                v[i].non_error_calls++;
            dump_rpu(o, rpu, &v[i], true);
            dovi_rpu_free(rpu);
        }
        DoviRpuOpaque *rpu = parsers[i].parse(nothing, 0);
        if (rpu && !dovi_rpu_get_error(rpu))
            v[i].non_error_calls++;
        dovi_rpu_free(rpu);
    }
    int bad = 0;
    bad += dovi_rpu_get_error(NULL) != NULL;
    dovi_rpu_free(NULL);
    dovi_data_free(NULL);
    bad += dovi_write_rpu(NULL) != NULL;
    bad += dovi_write_unspec62_nalu(NULL) != NULL;
    bad += dovi_write_av1_rpu_metadata_obu_t35_payload(NULL) != NULL;
    bad += dovi_write_av1_rpu_metadata_obu_t35_complete(NULL) != NULL;
    bad += dovi_convert_rpu_with_mode(NULL, 2) != -1;
    bad += dovi_rpu_get_header(NULL) != NULL;
    dovi_rpu_free_header(NULL);
    bad += dovi_rpu_get_data_mapping(NULL) != NULL;
    dovi_rpu_free_data_mapping(NULL);
    bad += dovi_rpu_get_vdr_dm_data(NULL) != NULL;
    dovi_rpu_free_vdr_dm_data(NULL);
    bad += dovi_parse_rpu_bin_file(NULL) != NULL;
    dovi_rpu_list_free(NULL);
    bad += dovi_rpu_set_active_area_offsets(NULL, 1, 2, 3, 4) != -1;
    bad += dovi_rpu_remove_mapping(NULL) != -1;
    fprintf(o, "  other entry points with null: %d unexpected results\n", bad);
    for (size_t i = 0; i < NUM_PARSERS; i++)
        v[i].non_error_calls += bad;
}

static const char *column(char *out, size_t n, const struct verdict *v)
{
    if (v->skipped)
        snprintf(out, n, "skip");
    else if (v->returned_null)
        snprintf(out, n, "null");
    else if (v->parsed)
        snprintf(out, n, "ok:%d", v->writer_failures);
    else if (v->non_error_calls)
        snprintf(out, n, "inconsistent");
    else
        snprintf(out, n, "err");
    return out;
}

/* A case that aborts or crashes exits with 128 + the signal number, so no
 * crash report is written for each of the unpatched library's aborts. */
static void crashed(int sig)
{
    _exit(128 + sig);
}

/* Runs in the child: exercises the case and writes the summary to fd. */
static void run_case(int fd, size_t index, int flags, const uint8_t *buf, size_t len,
                     const char *tmpdir, const char *dumpdir)
{
    static const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGSYS};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++)
        signal(signals[i], crashed);
    fprintf(stderr, "harness: case %zu\n", index);
    fflush(stderr);

    char *text = NULL;
    size_t text_len = 0;
    FILE *o = open_memstream(&text, &text_len);
    struct verdict v[NUM_PARSERS] = {{0}};

    alarm(CASE_TIMEOUT_SECONDS);
    if (flags & 2)
        exercise_null(o, v);
    const char *ffmpeg = (flags & 32) ? "skip-run" : ffmpeg_sequence(o, buf, len);
    const char *placebo = (flags & 32) ? "skip-run" : placebo_sequence(o, buf, len);
    for (size_t i = 0; i < NUM_PARSERS; i++) {
        if (flags & (4 << i))
            v[i].skipped = true;
        else
            exercise_parser(o, i, buf, len, &v[i]);
    }
    long bin = exercise_bin_file(o, tmpdir, buf, len);
    fclose(o);

    /* Digests of the whole dump and of the dump without error texts. */
    unsigned char digest[CC_SHA256_DIGEST_LENGTH], digest_results[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(text, (CC_LONG)text_len, digest);
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    for (char *line = text, *end; line < text + text_len; line = end + 1) {
        end = memchr(line, '\n', (size_t)(text + text_len - line));
        if (!end)
            end = text + text_len - 1;
        size_t n = (size_t)(end - line);
        if (memmem(line, n, " error: ", 8))
            continue;
        if ((n >= 14 && !memcmp(line, "  header: null", 14)) ||
            (n >= 20 && !memcmp(line, "  header: dm-missing", 20)))
            CC_SHA256_Update(&ctx, "  header: none\n", 15);
        else
            CC_SHA256_Update(&ctx, line, (CC_LONG)(n + 1));
    }
    CC_SHA256_Final(digest_results, &ctx);

    if ((flags & 1) && dumpdir) {
        char path[4096];
        snprintf(path, sizeof(path), "%s/%zu.txt", dumpdir, index);
        FILE *f = fopen(path, "w");
        if (!f || fwrite(text, 1, text_len, f) != text_len || fclose(f) != 0)
            _exit(3);
    }

    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);

    char line[768], cols[NUM_PARSERS][32];
    int n = snprintf(line, sizeof(line), "%s\t%s\t%s\t%s\t%s\t%s\t%d:%d:%d\t",
                     column(cols[0], sizeof(cols[0]), &v[0]),
                     column(cols[1], sizeof(cols[1]), &v[1]),
                     column(cols[2], sizeof(cols[2]), &v[2]),
                     bin < 0 ? "err" : (bin == 0 ? "empty" : "ok"), ffmpeg, placebo,
                     patch_texts, bad_patch_texts, header_rule);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        n += snprintf(line + n, sizeof(line) - n, "%02x", digest[i]);
    line[n++] = '\t';
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        n += snprintf(line + n, sizeof(line) - n, "%02x", digest_results[i]);
    n += snprintf(line + n, sizeof(line) - n, "\t%ld\n", (long)(ru.ru_maxrss / 1024));
    if (write(fd, line, n) != n)
        _exit(3);
    _exit(0);
}

static uint32_t be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s CASES TMPDIR [DUMPDIR]\n", argv[0]);
        return 2;
    }
    const char *tmpdir = argv[2], *dumpdir = argc > 3 ? argv[3] : NULL;

    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror(argv[1]);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *all = malloc(size > 0 ? (size_t)size : 1);
    if (!all || fread(all, 1, (size_t)size, f) != (size_t)size) {
        fprintf(stderr, "harness: cannot read %s\n", argv[1]);
        return 2;
    }
    fclose(f);
    if (size < 6 || memcmp(all, "LDVC1\n", 6) != 0) {
        fprintf(stderr, "harness: %s is not a case file\n", argv[1]);
        return 2;
    }

    size_t pos = 6, index = 0;
    while (pos < (size_t)size) {
        if (pos + 4 > (size_t)size)
            return 2;
        uint32_t name_len = be32(all + pos);
        pos += 4;
        if (pos + name_len + 5 > (size_t)size)
            return 2;
        pos += name_len;
        int flags = all[pos++];
        uint32_t len = be32(all + pos);
        pos += 4;
        if (pos + len > (size_t)size)
            return 2;
        /* Each case gets its own exact-size allocation, so reading past
         * the end of the input is not hidden by neighbouring cases. */
        uint8_t *buf = malloc(len ? len : 1);
        memcpy(buf, all + pos, len);
        pos += len;

        int fds[2];
        if (pipe(fds) != 0) {
            perror("pipe");
            return 2;
        }
        fflush(stdout);
        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            return 2;
        }
        if (pid == 0) {
            close(fds[0]);
            run_case(fds[1], index, flags, buf, len, tmpdir, dumpdir);
        }
        close(fds[1]);
        char summary[512];
        size_t got = 0;
        ssize_t r;
        while (got < sizeof(summary) - 1 &&
               (r = read(fds[0], summary + got, sizeof(summary) - 1 - got)) > 0)
            got += (size_t)r;
        summary[got] = '\0';
        close(fds[0]);
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
            ;
        if (WIFSIGNALED(status))
            printf("%zu\tsignal:%d%s\n", index, WTERMSIG(status), NO_RESULT);
        else if (WEXITSTATUS(status) != 0 || got == 0)
            printf("%zu\texit:%d%s\n", index, WEXITSTATUS(status), NO_RESULT);
        else
            printf("%zu\texit:0\t%s", index, summary);
        free(buf);
        index++;
    }
    return 0;
}
