<!-- read as: markdown -->
### Writing a Lexer and Parser in C

Here's a basic lexer and parser in C for a hypothetical programming language that supports integer types constrained to specific integer ranges. I'll provide the relevant code for lexing and parsing integer types with constraints.

### Lexer

#### Header (lexer.h)

c

```c
#ifndef LEXER_H
#define LEXER_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef enum {
    TOKEN_INT,
    TOKEN_RANGE,
    TOKEN_IDENTIFIER,
    TOKEN_LPAREN,
    TOKEN_RPAREN,
    TOKEN_COLON,
    TOKEN_COMMA,
    TOKEN_EOF,
    TOKEN_UNKNOWN
} TokenType;

typedef struct {
    TokenType type;
    char* value;
} Token;

typedef struct {
    const char* source;
    size_t length;
    size_t position;
} Lexer;

Lexer* create_lexer(const char* source);
void destroy_lexer(Lexer* lexer);
Token next_token(Lexer* lexer);
void destroy_token(Token token);

#endif // LEXER_H
```

#### Implementation (lexer.c)

c

```c
#include "lexer.h"

Lexer* create_lexer(const char* source) {
    Lexer* lexer = (Lexer*)malloc(sizeof(Lexer));
    lexer->source = source;
    lexer->length = strlen(source);
    lexer->position = 0;
    return lexer;
}

void destroy_lexer(Lexer* lexer) {
    free(lexer);
}

static char peek_char(Lexer* lexer) {
    if (lexer->position >= lexer->length) {
        return '\0';
    }
    return lexer->source[lexer->position];
}

static char advance_char(Lexer* lexer) {
    if (lexer->position >= lexer->length) {
        return '\0';
    }
    return lexer->source[lexer->position++];
}

static Token make_token(TokenType type, const char* value) {
    Token token;
    token.type = type;
    token.value = strdup(value);
    return token;
}

static void skip_whitespace(Lexer* lexer) {
    while (isspace(peek_char(lexer))) {
        advance_char(lexer);
    }
}

static Token scan_number(Lexer* lexer) {
    size_t start = lexer->position - 1;
    while (isdigit(peek_char(lexer))) {
        advance_char(lexer);
    }
    char* value = strndup(lexer->source + start, lexer->position - start);
    return make_token(TOKEN_INT, value);
}

static Token scan_identifier(Lexer* lexer) {
    size_t start = lexer->position - 1;
    while (isalnum(peek_char(lexer)) || peek_char(lexer) == '_') {
        advance_char(lexer);
    }
    char* value = strndup(lexer->source + start, lexer->position - start);
    return make_token(TOKEN_IDENTIFIER, value);
}

Token next_token(Lexer* lexer) {
    skip_whitespace(lexer);
    char current = advance_char(lexer);

    if (isdigit(current)) {
        return scan_number(lexer);
    }

    if (isalpha(current) || current == '_') {
        return scan_identifier(lexer);
    }

    switch (current) {
        case '\0': return make_token(TOKEN_EOF, "");
        case '(': return make_token(TOKEN_LPAREN, "(");
        case ')': return make_token(TOKEN_RPAREN, ")");
        case ':': return make_token(TOKEN_COLON, ":");
        case ',': return make_token(TOKEN_COMMA, ",");
        case '-':
            if (peek_char(lexer) == '>') {
                advance_char(lexer);
                return make_token(TOKEN_RANGE, "->");
            }
            break;
    }

    char unknown[2] = { current, '\0' };
    return make_token(TOKEN_UNKNOWN, unknown);
}

void destroy_token(Token token) {
    free(token.value);
}
```

### Parser

#### Header (parser.h)

c

```c
#ifndef PARSER_H
#define PARSER_H

#include "lexer.h"

typedef struct {
    char* name;
    int min_value;
    int max_value;
} ConstrainedIntType;

typedef struct {
    Lexer* lexer;
    Token current_token;
} Parser;

Parser* create_parser(const char* source);
void destroy_parser(Parser* parser);
ConstrainedIntType* parse_constrained_int_type(Parser* parser);

#endif // PARSER_H
```

#### Implementation (parser.c)

c

```c
#include "parser.h"

Parser* create_parser(const char* source) {
    Parser* parser = (Parser*)malloc(sizeof(Parser));
    parser->lexer = create_lexer(source);
    parser->current_token = next_token(parser->lexer);
    return parser;
}

void destroy_parser(Parser* parser) {
    destroy_token(parser->current_token);
    destroy_lexer(parser->lexer);
    free(parser);
}

static void consume_token(Parser* parser, TokenType expected) {
    if (parser->current_token.type == expected) {
        destroy_token(parser->current_token);
        parser->current_token = next_token(parser->lexer);
    } else {
        fprintf(stderr, "Error: Expected token of type %d but got %d\n", expected, parser->current_token.type);
        exit(1);
    }
}

static int parse_integer(Parser* parser) {
    int value = atoi(parser->current_token.value);
    consume_token(parser, TOKEN_INT);
    return value;
}

ConstrainedIntType* parse_constrained_int_type(Parser* parser) {
    ConstrainedIntType* result = (ConstrainedIntType*)malloc(sizeof(ConstrainedIntType));

    if (parser->current_token.type != TOKEN_IDENTIFIER) {
        fprintf(stderr, "Error: Expected identifier for type name\n");
        exit(1);
    }

    result->name = strdup(parser->current_token.value);
    consume_token(parser, TOKEN_IDENTIFIER);

    consume_token(parser, TOKEN_LPAREN);
    result->min_value = parse_integer(parser);
    consume_token(parser, TOKEN_RANGE);
    result->max_value = parse_integer(parser);
    consume_token(parser, TOKEN_RPAREN);

    return result;
}
```

### Main Program

To demonstrate the lexer and parser:

c

```c
#include <stdio.h>
#include "parser.h"

int main() {
    const char* source_code = "ConstrainedInt(0->100)";
    Parser* parser = create_parser(source_code);

    ConstrainedIntType* int_type = parse_constrained_int_type(parser);
    printf("Parsed constrained int type:\n");
    printf("Name: %s\n", int_type->name);
    printf("Range: %d -> %d\n", int_type->min_value, int_type->max_value);

    destroy_parser(parser);
    free(int_type->name);
    free(int_type);

    return 0;
}
```

### Compilation and Execution

1. Create files for the above code:
   - `lexer.h`
   - `lexer.c`
   - `parser.h`
   - `parser.c`
   - `main.c`
2. Compile using:

bash

```bash
gcc -o parser lexer.c parser.c main.c
```

3. Run:

bash

```bash
./parser
```

### Output

```
Parsed constrained int type:
Name: ConstrainedInt
Range: 0 -> 100
```

This provides a basic foundation for a lexer and parser in C that can recognize integer types with specific ranges. You can extend this further by adding more language features.
