// libass host test harness for Vivid's Lucid Engine
// (docs/cores/lucid-engine-build.md, "libass host tests").
//
// Reads a script of commands on stdin, drives one libass build through it and
// prints one line per rendered frame:
//
//   frame <tag> <index> <time> <change> <composite> <images> <count>
//         <attempts> <failures> <open-failures> <cache-bytes> <bad-types>
//         <render-ns> <faces-added> <unresolved>
//
// <composite> is a SHA-256 (first 128 bits) of the frame composited onto a
// black canvas with integer blending, canonicalised to its tight bounding
// box, so two frames hash alike exactly when they look alike. <images> hashes
// the image list itself (count, sizes, positions, colours and bitmap bytes).
// <bad-types> counts images whose type is not one of the three image types;
// libass leaves the type of a background box (BorderStyle 4) unset.
// <attempts>, <failures> and <open-failures> count libass's font fallback
// messages during that frame: searches, searches that found no font with
// the glyph, and fonts that could not be opened. <cache-bytes> is the size of the event render
// cache, read through libass's private headers when built with VIVID_PROBE
// (builds that have the cache), or -1. <render-ns> is the time
// ass_render_frame() took, in nanoseconds. <faces-added> and <unresolved>
// count the fallback faces added to fonts and the glyph lookups that no face
// could satisfy during that frame, read from the counters patch 0010 adds
// when built with VIVID_COUNTERS, or -1. Every render of an event with
// unresolved glyphs adds to <unresolved>, so it also counts those renders.
//
// Commands (paths and names are %-encoded, so "%20" is a space):
//   log <path>                         copy every libass message to a file
//   font <name> <path>                 ass_add_font() a file, before init
//   init <w> <h> <provider> <family|-> <font|->
//                                      provider: coretext or none
//   provider-font <family> <path|-> <weight> <lo-hi,...>
//                                      a font of the harness's own provider,
//                                      claiming the hexadecimal ranges
//   track <path>
//   render <tag> <t0> <step> <count>   render <count> frames from <t0> ms
//   frame-size <w> <h>                 ass_set_frame_size()
//   storage-size <w> <h>               ass_set_storage_size()
//   shaper <0|1>                       ass_set_shaper(), 0 simple, 1 complex
//   line-spacing <x>                   ass_set_line_spacing()
//   use-margins <0|1>                  ass_set_use_margins()
//   set-fonts <provider> <family|-> <font|->
//   style-size <index> <size>          change a style of the track in place
//   copy <from> <to>  /  remove <path> change a font file between frames
//   flush                              ass_flush_events()
//   probe <tag>                        print "probe <tag> <cache-bytes>"
//   heap <tag>                         print "heap <tag> <bytes in use>"
//
// Licence: ISC, like libass.

#include <CommonCrypto/CommonDigest.h>
#include <malloc/malloc.h>
#include <time.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ass.h"
#include "ass_fontselect.h"

#if defined(VIVID_PROBE) || defined(VIVID_COUNTERS)
#include "ass_render.h"
#endif
#ifdef VIVID_PROBE
// ass_cache.c keeps its cache structure private; this is its layout in
// libass 0.17.5. The bucket count (always 0xFFFF there) checks the layout.
struct probe_cache {
    unsigned buckets;
    void **map;
    void *queue_first, **queue_last;
    const void *desc;
    size_t cache_size;
};
#endif

static ASS_Library *library;
static ASS_Renderer *renderer;
static ASS_Track *track;
static FILE *message_log;
static unsigned long attempts, failures, open_failures;
static unsigned char *canvas;
static int canvas_w, canvas_h;

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("harness: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(2);
}

static void decode(char *s)
{
    char *w = s;
    for (char *r = s; *r; r++) {
        if (r[0] == '%' && r[1] && r[2]) {
            char hex[3] = { r[1], r[2], 0 };
            *w++ = (char) strtol(hex, NULL, 16);
            r += 2;
        } else {
            *w++ = *r;
        }
    }
    *w = 0;
}

static const char *opt(const char *s)
{
    return strcmp(s, "-") ? s : NULL;
}

static void on_message(int level, const char *fmt, va_list args, void *data)
{
    if (!strncmp(fmt, "Glyph 0x%X not found, selecting one more font", 45))
        attempts++;
    else if (!strncmp(fmt, "fontselect: failed to find any fallback", 39) ||
             !strncmp(fmt, "Glyph 0x%X not found in font for", 32))
        failures++;
    else if (!strncmp(fmt, "Error opening font", 18) ||
             !strncmp(fmt, "Error opening memory font", 25))
        open_failures++;
    if (message_log) {
        fprintf(message_log, "[%d] ", level);
        vfprintf(message_log, fmt, args);
        fputc('\n', message_log);
    }
}

static unsigned char *read_file(const char *path, size_t *size)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        die("cannot open %s", path);
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(n > 0 ? n : 1);
    if (!buf || fread(buf, 1, n, f) != (size_t) n)
        die("cannot read %s", path);
    fclose(f);
    *size = n;
    return buf;
}

static int provider_of(const char *name)
{
    if (!strcmp(name, "coretext"))
        return ASS_FONTPROVIDER_CORETEXT;
    if (!strcmp(name, "none"))
        return ASS_FONTPROVIDER_NONE;
    die("unknown font provider %s", name);
    return 0;
}

// ---------------------------------------------------- the harness's provider

typedef struct {
    int n;
    uint32_t lo[16], hi[16];
} Claims;

static bool claims_glyph(void *priv, uint32_t code)
{
    Claims *c = priv;
    if (!code)
        return true;
    for (int i = 0; i < c->n; i++)
        if (code >= c->lo[i] && code <= c->hi[i])
            return true;
    return false;
}

static void free_claims(void *priv)
{
    free(priv);
}

static ASS_FontProviderFuncs provider_funcs = {
    .check_glyph = claims_glyph,
    .destroy_font = free_claims,
};
static ASS_FontProvider *provider;

static void provider_font(char *family, char *path, int weight, char *ranges)
{
    if (!provider)
        provider = ass_create_font_provider(renderer, &provider_funcs, NULL);
    if (!provider)
        die("cannot create a font provider");
    Claims *c = calloc(1, sizeof(*c));
    for (char *r = strtok(ranges, ","); r && c->n < 16; r = strtok(NULL, ",")) {
        char *dash = strchr(r, '-');
        c->lo[c->n] = (uint32_t) strtoul(r, NULL, 16);
        c->hi[c->n] = dash ? (uint32_t) strtoul(dash + 1, NULL, 16) : c->lo[c->n];
        c->n++;
    }
    ASS_FontProviderMetaData meta = {0};
    meta.families = &family;
    meta.n_family = 1;
    meta.weight = weight;
    if (!ass_font_provider_add_font(provider, &meta, opt(path), 0, c))
        die("cannot add provider font %s", family);
}

// ------------------------------------------------------------------ frames

static long long cache_bytes(void)
{
#ifdef VIVID_PROBE
    struct probe_cache *c = (struct probe_cache *) renderer->cache.event_render_cache;
    if (c->buckets != 0xFFFF)
        die("event render cache layout differs from libass 0.17.5's");
    return (long long) c->cache_size;
#else
    return -1;
#endif
}

// Fallback faces added and glyph lookups that no face could satisfy so far,
// from patch 0010's counters, or -1 for builds without them.
static long long faces_added(void)
{
#ifdef VIVID_COUNTERS
    return (long long) renderer->fallback_faces;
#else
    return -1;
#endif
}

static long long unresolved_lookups(void)
{
#ifdef VIVID_COUNTERS
    return (long long) renderer->unresolved_glyphs;
#else
    return -1;
#endif
}

static void hex(const unsigned char *d, int n, char *out)
{
    for (int i = 0; i < n; i++)
        sprintf(out + 2 * i, "%02x", d[i]);
}

static void hash_images(ASS_Image *img, char *out)
{
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    for (; img; img = img->next) {
        int head[5] = { img->w, img->h, img->dst_x, img->dst_y, (int) img->color };
        CC_SHA256_Update(&ctx, head, sizeof(head));
        for (int y = 0; y < img->h; y++)
            CC_SHA256_Update(&ctx, img->bitmap + (size_t) y * img->stride, img->w);
    }
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(d, &ctx);
    hex(d, 16, out);
}

// Blend the frame onto a black RGB canvas with integer arithmetic, hash the
// tight bounding box of everything that is not black, then clear what was
// touched.
static void hash_composite(ASS_Image *list, char *out)
{
    int x0 = canvas_w, y0 = canvas_h, x1 = 0, y1 = 0;
    for (ASS_Image *img = list; img; img = img->next) {
        if (img->w <= 0 || img->h <= 0)
            continue;
        if (img->dst_x < 0 || img->dst_y < 0 ||
            img->dst_x + img->w > canvas_w || img->dst_y + img->h > canvas_h)
            die("image outside the frame at %d,%d", img->dst_x, img->dst_y);
        unsigned r = img->color >> 24, g = (img->color >> 16) & 0xFF,
                 b = (img->color >> 8) & 0xFF, a = 255 - (img->color & 0xFF);
        for (int y = 0; y < img->h; y++) {
            const unsigned char *src = img->bitmap + (size_t) y * img->stride;
            unsigned char *dst = canvas + ((size_t) (img->dst_y + y) * canvas_w + img->dst_x) * 3;
            for (int x = 0; x < img->w; x++, dst += 3) {
                unsigned k = (src[x] * a + 127) / 255;
                if (!k)
                    continue;
                dst[0] = (dst[0] * (255 - k) + r * k + 127) / 255;
                dst[1] = (dst[1] * (255 - k) + g * k + 127) / 255;
                dst[2] = (dst[2] * (255 - k) + b * k + 127) / 255;
            }
        }
        if (img->dst_x < x0) x0 = img->dst_x;
        if (img->dst_y < y0) y0 = img->dst_y;
        if (img->dst_x + img->w > x1) x1 = img->dst_x + img->w;
        if (img->dst_y + img->h > y1) y1 = img->dst_y + img->h;
    }
    int tx0 = canvas_w, ty0 = canvas_h, tx1 = 0, ty1 = 0;
    for (int y = y0; y < y1; y++) {
        const unsigned char *row = canvas + (size_t) y * canvas_w * 3;
        for (int x = x0; x < x1; x++) {
            if (row[3 * x] | row[3 * x + 1] | row[3 * x + 2]) {
                if (x < tx0) tx0 = x;
                if (x >= tx1) tx1 = x + 1;
                if (y < ty0) ty0 = y;
                if (y >= ty1) ty1 = y + 1;
            }
        }
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    if (tx1 > tx0) {
        int box[4] = { tx0, ty0, tx1, ty1 };
        CC_SHA256_Update(&ctx, box, sizeof(box));
        for (int y = ty0; y < ty1; y++)
            CC_SHA256_Update(&ctx, canvas + ((size_t) y * canvas_w + tx0) * 3,
                             (CC_LONG) (tx1 - tx0) * 3);
    }
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(d, &ctx);
    hex(d, 16, out);
    for (int y = y0; y < y1; y++)
        memset(canvas + ((size_t) y * canvas_w + x0) * 3, 0, (size_t) (x1 - x0) * 3);
}

// The composite depends only on the image list, which <images> hashes, and
// on the canvas, so a frame whose images hash like the previous frame's on
// the same canvas takes its composite without blending it again.
static char last_images[33], last_composite[33];

static void set_canvas(int w, int h)
{
    free(canvas);
    canvas = calloc((size_t) w * h, 3);
    if (!canvas)
        die("no memory for a %dx%d canvas", w, h);
    canvas_w = w;
    canvas_h = h;
    last_images[0] = 0;
}

static void render(const char *tag, long long t0, long long step, int count)
{
    if (!track)
        die("render before track");
    for (int i = 0; i < count; i++) {
        long long t = t0 + i * step;
        attempts = failures = open_failures = 0;
        int change = -1;
        long long faces = faces_added(), unresolved = unresolved_lookups();
        uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        ASS_Image *img = ass_render_frame(renderer, track, t, &change);
        uint64_t ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
        if (faces >= 0) {
            faces = faces_added() - faces;
            unresolved = unresolved_lookups() - unresolved;
        }
        char composite[33], images[33];
        hash_images(img, images);
        if (last_images[0] && !strcmp(images, last_images)) {
            memcpy(composite, last_composite, sizeof(composite));
        } else {
            hash_composite(img, composite);
            memcpy(last_images, images, sizeof(last_images));
            memcpy(last_composite, composite, sizeof(last_composite));
        }
        int n = 0, bad_types = 0;
        for (ASS_Image *p = img; p; p = p->next) {
            n++;
            if ((unsigned) p->type > IMAGE_TYPE_SHADOW)
                bad_types++;
        }
        printf("frame %s %d %lld %d %s %s %d %lu %lu %lu %lld %d %llu %lld %lld\n", tag, i, t,
               change, composite, images, n, attempts, failures, open_failures, cache_bytes(),
               bad_types, (unsigned long long) ns, faces, unresolved);
    }
}

static void copy_file(const char *from, const char *to)
{
    size_t size;
    unsigned char *data = read_file(from, &size);
    FILE *f = fopen(to, "wb");
    if (!f || fwrite(data, 1, size, f) != size || fclose(f))
        die("cannot write %s", to);
    free(data);
}

int main(void)
{
    char line[4096];
    char *arg[16];
    library = ass_library_init();
    if (!library)
        die("ass_library_init failed");
    ass_set_message_cb(library, on_message, NULL);
    while (fgets(line, sizeof(line), stdin)) {
        int n = 0;
        for (char *tok = strtok(line, " \t\r\n"); tok && n < 16; tok = strtok(NULL, " \t\r\n")) {
            decode(tok);
            arg[n++] = tok;
        }
        if (!n || arg[0][0] == '#')
            continue;
        const char *cmd = arg[0];
#define NEED(k) do { if (n < (k) + 1) die("%s needs %d arguments", cmd, k); } while (0)
        if (!strcmp(cmd, "log")) {
            NEED(1);
            message_log = fopen(arg[1], "w");
        } else if (!strcmp(cmd, "font")) {
            NEED(2);
            size_t size;
            unsigned char *data = read_file(arg[2], &size);
            ass_add_font(library, arg[1], (const char *) data, (int) size);
            free(data);
        } else if (!strcmp(cmd, "init")) {
            NEED(5);
            renderer = ass_renderer_init(library);
            if (!renderer)
                die("ass_renderer_init failed");
            int w = atoi(arg[1]), h = atoi(arg[2]);
            ass_set_frame_size(renderer, w, h);
            ass_set_storage_size(renderer, w, h);
            set_canvas(w, h);
            ass_set_fonts(renderer, opt(arg[5]), opt(arg[4]), provider_of(arg[3]), NULL, 1);
        } else if (!strcmp(cmd, "provider-font")) {
            NEED(4);
            provider_font(arg[1], arg[2], atoi(arg[3]), arg[4]);
        } else if (!strcmp(cmd, "track")) {
            NEED(1);
            if (track)
                ass_free_track(track);
            track = ass_read_file(library, arg[1], NULL);
            if (!track)
                die("cannot read %s", arg[1]);
        } else if (!strcmp(cmd, "render")) {
            NEED(4);
            render(arg[1], atoll(arg[2]), atoll(arg[3]), atoi(arg[4]));
        } else if (!strcmp(cmd, "frame-size")) {
            NEED(2);
            ass_set_frame_size(renderer, atoi(arg[1]), atoi(arg[2]));
            set_canvas(atoi(arg[1]), atoi(arg[2]));
        } else if (!strcmp(cmd, "storage-size")) {
            NEED(2);
            ass_set_storage_size(renderer, atoi(arg[1]), atoi(arg[2]));
        } else if (!strcmp(cmd, "shaper")) {
            NEED(1);
            ass_set_shaper(renderer, atoi(arg[1]) ? ASS_SHAPING_COMPLEX : ASS_SHAPING_SIMPLE);
        } else if (!strcmp(cmd, "line-spacing")) {
            NEED(1);
            ass_set_line_spacing(renderer, atof(arg[1]));
        } else if (!strcmp(cmd, "use-margins")) {
            NEED(1);
            ass_set_use_margins(renderer, atoi(arg[1]));
        } else if (!strcmp(cmd, "set-fonts")) {
            NEED(3);
            provider = NULL;  // freed with the old font selector
            ass_set_fonts(renderer, opt(arg[3]), opt(arg[2]), provider_of(arg[1]), NULL, 1);
        } else if (!strcmp(cmd, "style-size")) {
            NEED(2);
            int i = atoi(arg[1]);
            if (!track || i < 0 || i >= track->n_styles)
                die("no style %d", i);
            track->styles[i].FontSize = atof(arg[2]);
        } else if (!strcmp(cmd, "copy")) {
            NEED(2);
            copy_file(arg[1], arg[2]);
        } else if (!strcmp(cmd, "remove")) {
            NEED(1);
            remove(arg[1]);
        } else if (!strcmp(cmd, "flush")) {
            ass_flush_events(track);
        } else if (!strcmp(cmd, "probe")) {
            NEED(1);
            printf("probe %s %lld\n", arg[1], cache_bytes());
        } else if (!strcmp(cmd, "heap")) {
            NEED(1);
            malloc_statistics_t st;
            malloc_zone_statistics(NULL, &st);
            printf("heap %s %zu\n", arg[1], st.size_in_use);
        } else {
            die("unknown command %s", cmd);
        }
        fflush(stdout);
    }
    if (track)
        ass_free_track(track);
    if (renderer)
        ass_renderer_done(renderer);
    ass_library_done(library);
    free(canvas);
    if (message_log)
        fclose(message_log);
    printf("done\n");
    return 0;
}
