// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

#ifndef TYPESET_TINYMIST_H
#define TYPESET_TINYMIST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TypesetTinymistSession TypesetTinymistSession;

TypesetTinymistSession *typeset_tinymist_session_create(void);
void typeset_tinymist_session_destroy(TypesetTinymistSession *session);
char *typeset_tinymist_set_debug_logging(TypesetTinymistSession *session, uint8_t enabled);
char *typeset_tinymist_set_workspace(TypesetTinymistSession *session, const char *root, const char *compile_target);
char *typeset_tinymist_set_package_storage(TypesetTinymistSession *session, const char *package_path, const char *package_cache_path);
char *typeset_tinymist_update_file(TypesetTinymistSession *session, const char *path, const char *text);
char *typeset_tinymist_close_file(TypesetTinymistSession *session, const char *path);
char *typeset_tinymist_diagnostics(TypesetTinymistSession *session);
char *typeset_tinymist_completions(TypesetTinymistSession *session, const char *path, uint32_t utf8_offset);
char *typeset_tinymist_hover(TypesetTinymistSession *session, const char *path, uint32_t utf8_offset);
char *typeset_tinymist_signature_help(TypesetTinymistSession *session, const char *path, uint32_t utf8_offset);
char *typeset_tinymist_prose_ranges(TypesetTinymistSession *session, const char *path);
char *typeset_tinymist_prose_ranges_with_options(TypesetTinymistSession *session, const char *path, uint8_t ignore_commands);
char *typeset_tinymist_document_symbols(TypesetTinymistSession *session, const char *path);
char *typeset_typst_compile_svg(const char *root, const char *main_path, const char *package_path, const char *package_cache_path);
char *typeset_typst_compile_pdf(const char *root, const char *main_path, const char *package_path, const char *package_cache_path);
char *typeset_typst_compile_html(const char *root, const char *main_path, const char *package_path, const char *package_cache_path);
char *typeset_typst_version(void);
void typeset_tinymist_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
