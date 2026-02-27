#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

typedef struct ghostty_sgr_attr {
    int tag;
    union {
        uint64_t _padding[8];
    } value;
} ghostty_sgr_attr;

int ghostty_sgr_new(const void *allocator, void **out_parser) {
    (void)allocator;
    if (out_parser == NULL) return -1;
    *out_parser = malloc(1);
    return (*out_parser == NULL) ? -1 : 0;
}

void ghostty_sgr_free(void *parser) {
    free(parser);
}

int ghostty_sgr_set_params(
    void *parser,
    const uint16_t *params,
    const uint8_t *subparams,
    size_t count
) {
    (void)parser;
    (void)params;
    (void)subparams;
    (void)count;
    return 0;
}

int ghostty_sgr_next(void *parser, ghostty_sgr_attr *out_attr) {
    (void)parser;
    (void)out_attr;
    return 0;
}
