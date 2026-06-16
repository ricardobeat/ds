; ── Comments ──────────────────────────────────────────────────
(comment) @comment

; ── Keywords ──────────────────────────────────────────────────
"let" @keyword
"fn" @keyword
"if" @keyword
"then" @keyword
"else" @keyword
"throw" @keyword
"try" @keyword
"catch" @keyword
"match" @keyword
"and" @keyword
"or" @keyword

; ── Import / type keywords (qualified to avoid Zed parser issues) ─
(import_declaration "from" @keyword)
(import_declaration "import" @keyword)
(type_declaration "type" @keyword)

; ── Literals ──────────────────────────────────────────────────
(string) @string
(number) @number
(boolean) @constant
(nil_literal) @constant

; ── Operators ─────────────────────────────────────────────────
"=" @operator
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"<" @operator
">" @operator
"<=" @operator
">=" @operator
"===" @operator
"!==" @operator
".." @operator
"!" @operator
"->" @operator
"??" @operator

; ── Signal sugar ──────────────────────────────────────────────
"$" @punctuation

(signal_read
  name: (identifier) @variable)

(signal_write
  name: (identifier) @variable)

; ── Punctuation ───────────────────────────────────────────────
"(" @punctuation
")" @punctuation
"[" @punctuation
"]" @punctuation
"{" @punctuation
"}" @punctuation
"," @punctuation
";" @punctuation
":" @punctuation
"." @punctuation

; ── Functions ─────────────────────────────────────────────────
(call_expression
  function: (identifier) @function)

(call_expression
  function: (member_expression
    property: (identifier) @function))

; ── Parameters ────────────────────────────────────────────────
(parameter
  name: (identifier) @variable)

; ── Fields ────────────────────────────────────────────────────
(field
  key: (identifier) @property)

; ── Member access ─────────────────────────────────────────────
(member_expression
  property: (identifier) @property)

; ── Let bindings ──────────────────────────────────────────────
(let_declaration
  name: (identifier) @variable)

; ── Import bindings ───────────────────────────────────────────
(import_declaration
  module: (identifier) @namespace)

(import_declaration
  (identifier) @variable)

; ── Type declarations ─────────────────────────────────────────
(type_declaration
  name: (identifier) @type)

; ── Functions (named) ─────────────────────────────────────────
(fn_declaration
  name: (identifier) @function)

(fn_declaration
  return_type: (type_name) @type)

; ── Destructuring parameters ───────────────────────────────────
(destructure_parameter
  field: (identifier) @variable)

; ── Match ─────────────────────────────────────────────────────
(match_arm
  tag: (upper_identifier) @constructor)

(match_arm
  binding: (identifier) @variable)

; ── Primitive match ────────────────────────────────────────────
(primitive_match_arm
  pattern: (string) @string)

(primitive_match_arm
  pattern: (number) @number)

(primitive_match_arm
  pattern: (boolean) @constant)

(primitive_match_arm
  pattern: (nil_literal) @constant)

(wildcard) @variable.special

; ── Elements (JSX-like) ───────────────────────────────────────
(element_expression
  tag: (identifier) @tag)

(element_expression
  open_tag: (identifier) @tag)

(element_expression
  close_tag: (identifier) @tag)

(element_attribute
  name: (identifier) @tag)

(element_attribute
  value: (string) @string)

; ── Type annotations ──────────────────────────────────────────
(type_name) @type

(type_record
  (type_field
    (identifier) @property))

(parameter
  type: (type_name) @type)

(let_declaration
  type: (type_name) @type)

(fn_expression
  return_type: (type_name) @type)

; ── Identifiers ───────────────────────────────────────────────
(identifier) @variable
