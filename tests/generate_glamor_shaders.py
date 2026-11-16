#!/usr/bin/env python3
"""Generates every GLSL program Xwayland 24.1's glamor builds on a GLES 3
context (GLSL ES 3.00: glsl_version 300, is_gles), as glamor assembles
them: a C harness made of glamor's own facet tables, templates and
composite-shader builders (extracted from its sources), run once.

  python3 tests/generate_glamor_shaders.py <xwayland-24.1 source> <out dir> <work dir>

Writes <out>/<name>.vert and .frag pairs, and <out>/LIST, for
tests/test_gfxapi_webrender.sig's glamor test (GFXAPI_GLAMOR_SHADERS=<out>).
Needs a C compiler (gcc) for the harness; the source is xwayland-24.1.x's
tarball (xorg.freedesktop.org/archive/individual/xserver/), MIT licensed.
"""
import os
import re
import subprocess
import sys

src, out, work = sys.argv[1:4]
G = os.path.join(src, 'glamor')


def read(name):
    return open(os.path.join(G, name), encoding='utf-8').read()


def block_from(text, start_pat):
    """The text from start_pat's match to its matching closing brace and ';'."""
    m = re.search(start_pat, text, re.M)
    if not m:
        raise SystemExit('not found: ' + start_pat)
    i = text.index('{', m.start())
    depth = 0
    j = i
    while True:
        c = text[j]
        if c == '"':
            j += 1
            while text[j] != '"':
                if text[j] == '\\':
                    j += 1
                j += 1
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                break
        j += 1
    end = text.index(';', j) if text[j + 1:].lstrip().startswith(';') else j
    return text[m.start():end + 1]


def facets(text):
    names = re.findall(r'^(?:static\s+)?const glamor_facet (\w+) = \{', text, re.M)
    out = []
    for n in names:
        b = block_from(text, r'^(?:static\s+)?const glamor_facet ' + n + r' = \{')
        b = re.sub(r'^\s*\.use(_render)?\s*=\s*\w+\s*,?\s*$', '', b, flags=re.M)
        b = re.sub(r'^(?:static\s+)?const glamor_facet', 'static glamor_facet', b)
        out.append((n, b))
    return out


def strings(text):
    """static const char NAME[] = "..." ...; definitions, whole."""
    found = []
    for m in re.finditer(r'^static const char (\w+)\[\]\s*=', text, re.M):
        j = m.end()
        while text[j] != ';':
            if text[j] == '"':
                j += 1
                while text[j] != '"':
                    if text[j] == '\\':
                        j += 1
                    j += 1
            j += 1
        found.append(text[m.start():j + 1])
    return found


def macros(text, names):
    lines = text.split('\n')
    out = []
    i = 0
    skip = False
    while i < len(lines):
        l = lines[i]
        if l.startswith('#if 0'):
            skip = True
        elif skip and l.startswith('#endif'):
            skip = False
        elif not skip and any(re.match(r'#define\s+' + n + r'\b', l) for n in names):
            out.append(l)
            while l.endswith('\\'):
                i += 1
                l = lines[i]
                out.append(l)
        i += 1
    return '\n'.join(out)


priv = read('glamor_priv.h')
trans = read('glamor_transform.h')
progh = read('glamor_program.h')
progc = read('glamor_program.c')
render = read('glamor_render.c')

prelude = r'''
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int Bool;
typedef unsigned GLuint;
typedef int GLint;
#define TRUE 1
#define FALSE 0
#define GL_VERTEX_SHADER 1
#define GL_FRAGMENT_SHADER 2
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define FatalError(...) abort()
#define XNFasprintf asprintf
'''
prelude += macros(priv, ['GLAMOR_DEFAULT_PRECISION', 'GLAMOR_DEFAULT_POINT_SIZE', 'GLAMOR_COMPAT_DEFINES_VS', 'GLAMOR_COMPAT_DEFINES_FS']) + '\n'
prelude += macros(trans, ['GLAMOR_DECLARE_MATRIX', 'GLAMOR_X_POS', 'GLAMOR_Y_POS', 'GLAMOR_POS']) + '\n'
for pat in [r'^typedef enum \{\n    glamor_program_location_none', r'^typedef enum \{\n    glamor_program_flag_none', r'^typedef enum \{\n    glamor_program_alpha_normal',
            r'^typedef enum \{\n    glamor_program_source_solid']:
    b = block_from(progh, pat)
    b = b + ' ' + re.match(r'\s*(\w+);', progh[progh.index(b) + len(b):]).group(1) + ';'
    prelude += b + '\n'
for pat in [r'^enum shader_source', r'^enum shader_mask', r'^enum shader_dest_swizzle', r'^struct shader_key']:
    prelude += block_from(priv, pat) + '\n'
prelude += r'''
typedef struct {
    const char *name;
    const int version;
    char *vs_extensions;
    const char *fs_extensions;
    const char *vs_vars;
    const char *vs_exec;
    const char *fs_vars;
    const char *fs_exec;
    const glamor_program_location locations;
    const glamor_program_flag flags;
    const char *source_name;
} glamor_facet;
typedef struct { int is_gles; int glsl_version; int use_gpu_shader4; } glamor_screen_private;
static const char *out_dir;
static const char *current;
static FILE *list;
static GLuint glamor_compile_glsl_prog(int kind, const char *source)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s.%s", out_dir, current, kind == GL_VERTEX_SHADER ? "vert" : "frag");
    FILE *f = fopen(path, "w");
    fputs(source, f);
    fclose(f);
    return 1;
}
'''

# glamor_program.c: the fill facets, location vars, templates
body = ''
for n, b in facets(progc):
    body += b + '\n'
lv = progc[progc.index('typedef struct {\n    glamor_program_location     location;'):progc.index('static const glamor_facet facet_null_fill')]
body += lv
body += block_from(progc, r'^static const char \*glamor_combine\[\]') + '\n'

# every other file's facets
files = ['glamor_copy.c', 'glamor_dash.c', 'glamor_glyphblt.c', 'glamor_lines.c', 'glamor_points.c', 'glamor_rects.c',
         'glamor_segs.c', 'glamor_spans.c', 'glamor_text.c', 'glamor_xv.c', 'glamor_composite_glyphs.c']
for fn in files:
    t = read(fn)
    # file-local string macros a facet may use
    defs = re.findall(r'^#define\s+(\w+)\s+"', t, re.M)
    if defs:
        body += macros(t, defs) + '\n'
    for d in strings(t):
        body += d + '\n'
    for n, b in facets(t):
        body += b + '\n'

# glamor_render.c's composite builders
body += 'static glamor_screen_private *glamor_priv_global;\n'
body += '#define RepeatFix 10\n'
body += block_from(render, r'^glamor_create_composite_fs\(').replace('glamor_create_composite_fs(', 'static GLuint glamor_create_composite_fs(', 1) + '\n'
body += block_from(render, r'^glamor_create_composite_vs\(').replace('glamor_create_composite_vs(', 'static GLuint glamor_create_composite_vs(', 1) + '\n'

body += r'''
/* glamor_build_program's assembly (glamor_program.c), for one GLES 3 context */
static void build(const char *name, glamor_screen_private *glamor_priv, const glamor_facet *prim,
                  const glamor_facet *fill, const char *combine, const char *defines)
{
    static const glamor_facet facet_null_fill = { .name = "" };
    int version = prim->version;
    glamor_program_location locations = prim->locations;
    char *version_string = NULL, *vs_vars, *fs_vars, *vs, *fs;
    int gpu_shader4 = 0;
    if (!fill)
        fill = &facet_null_fill;
    locations |= fill->locations;
    version = MAX(version, fill->version);
    if (version > glamor_priv->glsl_version) {
        if (version == 130 && !glamor_priv->use_gpu_shader4) {
            fprintf(list, "# %s: not built (GLSL %d)\n", name, version);
            return;
        }
        version = 120;
        gpu_shader4 = 1;
    }
    if (version == 130 && glamor_priv->is_gles && glamor_priv->glsl_version > 110)
        version = 300;
    else if (glamor_priv->is_gles)
        version = 100;
    else if (!version)
        version = 120;
    vs_vars = vs_location_vars(locations);
    fs_vars = fs_location_vars(locations);
    asprintf(&version_string, "#version %d %s\n", version, glamor_priv->is_gles && version > 100 ? "es" : "");
    asprintf(&vs, vs_template, str(version_string),
             gpu_shader4 ? "#extension GL_EXT_gpu_shader4 : require\n" : "",
             version < 130 ? GLAMOR_COMPAT_DEFINES_VS : "",
             str(defines), str(prim->vs_vars), str(fill->vs_vars), vs_vars,
             str(prim->vs_exec), str(fill->vs_exec));
    asprintf(&fs, fs_template, str(version_string), str(prim->fs_extensions), str(fill->fs_extensions),
             gpu_shader4 ? "#extension GL_EXT_gpu_shader4 : require\n#define texelFetch texelFetch2D\n#define uint unsigned int\n" : "",
             GLAMOR_COMPAT_DEFINES_FS, str(defines), str(prim->fs_vars), str(fill->fs_vars), fs_vars,
             str(prim->fs_exec), str(fill->fs_exec), str(combine));
    current = name;
    glamor_compile_glsl_prog(GL_VERTEX_SHADER, vs);
    glamor_compile_glsl_prog(GL_FRAGMENT_SHADER, fs);
    fprintf(list, "%s %s %s\n", name, prim->source_name ? prim->source_name : "-",
            combine && strstr(combine, "color1") ? "dual" : "-");
}

int main(int argc, char **argv)
{
    glamor_screen_private priv = { .is_gles = 1, .glsl_version = 300, .use_gpu_shader4 = 0 };
    char name[256];
    out_dir = argv[1];
    snprintf(name, sizeof name, "%s/LIST", out_dir);
    list = fopen(name, "w");
    static const char *fill_names[4] = { "solid", "tile", "stipple", "opaque_stipple" };
    const glamor_facet *fills[4] = { &glamor_fill_solid, &glamor_fill_tile, &glamor_fill_stipple, &glamor_fill_opaque_stipple };
    struct { const char *n; const glamor_facet *f; } fill_prims[] = {
        { "polyfillrect", &glamor_facet_polyfillrect_130 },
        { "fillspans", &glamor_facet_fillspans_130 },
        { "poly_segment", &glamor_facet_poly_segment },
        { "poly_lines", &glamor_facet_poly_lines },
        { "poly_glyph_blt", &glamor_facet_poly_glyph_blt },
        { "poly_text", &glamor_facet_poly_text },
        { "on_off_dash", &glamor_facet_on_off_dash_lines },
    };
    for (unsigned p = 0; p < ARRAY_SIZE(fill_prims); p++)
        for (int f = 0; f < 4; f++) {
            snprintf(name, sizeof name, "%s_%s", fill_prims[p].n, fill_names[f]);
            build(strdup(name), &priv, fill_prims[p].f, fills[f], NULL, NULL);
        }
    build("copy_area", &priv, &glamor_facet_copyarea, NULL, NULL, NULL);
    build("copy_plane", &priv, &glamor_facet_copyplane, NULL, NULL, NULL);
    build("point", &priv, &glamor_facet_point, &glamor_fill_solid, NULL, NULL);
    build("double_dash", &priv, &glamor_facet_double_dash_lines, NULL, NULL, NULL);
    build("image_text", &priv, &glamor_facet_image_text, &glamor_facet_image_fill, NULL, NULL);
    build("te_text", &priv, &glamor_facet_te_text, NULL, NULL, NULL);
    build("xv_planar_2", &priv, &glamor_facet_xv_planar_2, NULL, NULL, NULL);
    build("xv_planar_3", &priv, &glamor_facet_xv_planar_3, NULL, NULL, NULL);
    build("xv_uyvy", &priv, &glamor_facet_xv_uyvy, NULL, NULL, NULL);
    build("xv_rgb_raw", &priv, &glamor_facet_xv_rgb_raw, NULL, NULL, NULL);
    /* render programs: composite glyphs (ES 3.00's), each source, normal
     * alpha and component alpha's first pass (no dual-source blending on
     * this GL) */
    /* glamor_composite_glyphs_init's defines: the atlas (1024 pixels a side
     * when the GL allows that much) */
    char *glyph_defines = NULL;
    asprintf(&glyph_defines, "#define ATLAS_DIM_INV %20.18f\n", 1.0 / 1024);
    static const char *src_names[3] = { "solid", "picture", "1x1" };
    const glamor_facet *sources[3] = { &glamor_source_solid, &glamor_source_picture, &glamor_source_1x1_picture };
    for (int s = 0; s < 3; s++)
        for (int a = 0; a < 2; a++) {
            snprintf(name, sizeof name, "composite_glyphs_%s_%s", src_names[s], a ? "ca_first" : "normal");
            build(strdup(name), &priv, &glamor_facet_composite_glyphs_es300, sources[s], glamor_combine[a], glyph_defines);
        }
    /* glamor_render.c's composite shaders: every key */
    for (int so = 0; so < SHADER_SOURCE_COUNT; so++)
        for (int m = 0; m < SHADER_MASK_COUNT; m++)
            for (int in = 0; in < 3; in++)
                for (int d = 0; d < SHADER_DEST_SWIZZLE_COUNT; d++) {
                    struct shader_key key = { .source = so, .mask = m, .in = in, .dest_swizzle = d };
                    if (in != glamor_program_alpha_normal && m == SHADER_MASK_NONE)
                        continue;
                    snprintf(name, sizeof name, "render_s%d_m%d_in%d_d%d", so, m, in, d);
                    current = strdup(name);
                    glamor_create_composite_vs(&priv, &key);
                    glamor_create_composite_fs(&priv, &key, TRUE);
                    fprintf(list, "%s render -\n", name);
                }
    fclose(list);
    return 0;
}
'''

os.makedirs(work, exist_ok=True)
os.makedirs(out, exist_ok=True)
c = os.path.join(work, 'glamor_gen.c')
open(c, 'w').write(prelude + body)
exe = os.path.join(work, 'glamor_gen')
subprocess.check_call(['gcc', '-std=gnu11', '-w', '-o', exe, c])
subprocess.check_call([exe, out])
print(open(os.path.join(out, 'LIST')).read())
