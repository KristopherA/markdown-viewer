#ifndef MARKDOWN_GFM_H
#define MARKDOWN_GFM_H

#include <stddef.h>

/// Renders GitHub Flavored Markdown to HTML.
/// The caller frees the result with markdown_render_gfm_free.
char *markdown_render_gfm(const char *text, size_t length);
void markdown_render_gfm_free(char *html);

#endif
