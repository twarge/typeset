// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

#ifndef TYPESET_LANG_H
#define TYPESET_LANG_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TypesetLangSession TypesetLangSession;

TypesetLangSession *typeset_lang_session_create(void);
void typeset_lang_session_destroy(TypesetLangSession *session);
char *typeset_lang_set_debug_logging(TypesetLangSession *session, uint8_t enabled);
char *typeset_lang_set_workspace(TypesetLangSession *session, const char *root, const char *compile_target);
char *typeset_lang_set_package_storage(TypesetLangSession *session, const char *package_path, const char *package_cache_path);
char *typeset_lang_update_file(TypesetLangSession *session, const char *path, const char *text);
char *typeset_lang_close_file(TypesetLangSession *session, const char *path);
char *typeset_lang_diagnostics(TypesetLangSession *session);
char *typeset_lang_completions(TypesetLangSession *session, const char *path, uint32_t utf8_offset);
char *typeset_lang_hover(TypesetLangSession *session, const char *path, uint32_t utf8_offset);
char *typeset_lang_signature_help(TypesetLangSession *session, const char *path, uint32_t utf8_offset);
char *typeset_lang_prose_ranges(TypesetLangSession *session, const char *path);
char *typeset_lang_prose_ranges_with_options(TypesetLangSession *session, const char *path, uint8_t ignore_commands);
char *typeset_lang_document_symbols(TypesetLangSession *session, const char *path);
char *typeset_lang_definition(TypesetLangSession *session, const char *path, uint32_t utf8_offset);
char *typeset_lang_references(TypesetLangSession *session, const char *path, uint32_t utf8_offset);
char *typeset_lang_selection_ranges(TypesetLangSession *session, const char *path, uint32_t start_utf8, uint32_t end_utf8);
char *typeset_lang_prepare_rename(TypesetLangSession *session, const char *path, uint32_t utf8_offset);
char *typeset_lang_rename(TypesetLangSession *session, const char *path, uint32_t utf8_offset, const char *new_name);
char *typeset_lang_format(TypesetLangSession *session, const char *path, uint32_t start_utf8, uint32_t end_utf8, uint8_t selection_only);
char *typeset_lang_code_actions(TypesetLangSession *session, const char *path, uint32_t start_utf8, uint32_t end_utf8);
char *typeset_typst_compile_svg(const char *root, const char *main_path, const char *package_path, const char *package_cache_path);
char *typeset_typst_compile_pdf(const char *root, const char *main_path, const char *package_path, const char *package_cache_path);
char *typeset_typst_compile_html(const char *root, const char *main_path, const char *package_path, const char *package_cache_path);
char *typeset_typst_version(void);
void typeset_lang_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
