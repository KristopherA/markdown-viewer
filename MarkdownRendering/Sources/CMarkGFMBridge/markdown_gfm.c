#include "markdown_gfm.h"

#include <cmark.h>
#include <stdlib.h>

void cmark_gfm_core_extensions_ensure_registered(void);
cmark_syntax_extension *cmark_find_syntax_extension(const char *name);
int cmark_parser_attach_syntax_extension(cmark_parser *parser, cmark_syntax_extension *extension);
cmark_llist *cmark_parser_get_syntax_extensions(cmark_parser *parser);

static void attach_extension(cmark_parser *parser, const char *name) {
    cmark_syntax_extension *extension = cmark_find_syntax_extension(name);
    if (extension) {
        cmark_parser_attach_syntax_extension(parser, extension);
    }
}

char *markdown_render_gfm(const char *text, size_t length) {
    // CMARK_OPT_GITHUB_PRE_LANG emits <pre lang="x">. Highlighting needs
    // class="language-x", which is the renderer default, so that option stays off.
    int options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_VALIDATE_UTF8;
    static int registered = 0;
    if (!registered) {
        cmark_gfm_core_extensions_ensure_registered();
        registered = 1;
    }

    cmark_parser *parser = cmark_parser_new(options);
    if (!parser) {
        return NULL;
    }

    attach_extension(parser, "table");
    attach_extension(parser, "strikethrough");
    attach_extension(parser, "autolink");
    attach_extension(parser, "tagfilter");
    attach_extension(parser, "tasklist");
    attach_extension(parser, "footnotes");
    attach_extension(parser, "alerts");

    cmark_parser_feed(parser, text, length);
    cmark_node *document = cmark_parser_finish(parser);
    if (!document) {
        cmark_parser_free(parser);
        return NULL;
    }

    cmark_llist *extensions = cmark_parser_get_syntax_extensions(parser);
    char *html = cmark_render_html(document, options, extensions);
    cmark_node_free(document);
    cmark_parser_free(parser);
    return html;
}

void markdown_render_gfm_free(char *html) {
    free(html);
}
