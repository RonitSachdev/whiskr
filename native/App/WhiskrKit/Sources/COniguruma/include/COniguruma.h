/* Whiskr's view of Oniguruma (not part of Oniguruma): its API, and the encoding and syntax Whiskr uses as
   functions, since Swift does not import the macros that name them. */
#ifndef WHISKR_CONIGURUMA_H
#define WHISKR_CONIGURUMA_H

#include "oniguruma.h"

/* Text is searched as UTF-8, as VS Code searches it. */
static inline OnigEncoding whiskr_onig_utf8(void) { return ONIG_ENCODING_UTF8; }

/* Ruby's syntax, Oniguruma's default: what TextMate grammars are written in. */
static inline OnigSyntaxType *whiskr_onig_syntax(void) { return ONIG_SYNTAX_DEFAULT; }

/* Every group captures, named or not, as in VS Code. */
static inline OnigOptionType whiskr_onig_capture_group(void) { return ONIG_OPTION_CAPTURE_GROUP; }

#endif
