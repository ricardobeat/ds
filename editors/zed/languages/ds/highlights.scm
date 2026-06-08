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
"from" @keyword.import
"import" @keyword.import
"type" @keyword

; ── Literals ──────────────────────────────────────────────────
(string) @string
(number) @number
(boolean) @constant.builtin
(nil_literal) @constant.builtin

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

; ── Logical keywords used as operators ────────────────────────
"and" @keyword.operator
"or" @keyword.operator

; ── Signal sugar ──────────────────────────────────────────────
"$" @punctuation.special

(signal_read
  name: (identifier) @variable)

(signal_write
  name: (identifier) @variable)

; ── Punctuation ───────────────────────────────────────────────
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"," @punctuation.delimiter
";" @punctuation.delimiter
":" @punctuation.delimiter
"." @punctuation.delimiter

; ── Functions ─────────────────────────────────────────────────
(fn_expression
  "fn" @keyword.function)

(call_expression
  function: (identifier) @function.call)

(call_expression
  function: (member_expression
    property: (identifier) @function.method.call))

; ── Parameters ────────────────────────────────────────────────
(parameter
  name: (identifier) @variable.parameter)

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
  module: (identifier) @module)

(import_declaration
  (identifier) @variable)

; ── Type declarations ─────────────────────────────────────────
(type_declaration
  name: (identifier) @type)

; ── Match ─────────────────────────────────────────────────────
(match_arm
  tag: (upper_identifier) @constructor)

(match_arm
  binding: (identifier) @variable.parameter)

; ── Elements (JSX-like) ───────────────────────────────────────
(element_expression
  tag: (identifier) @tag)

(element_expression
  open_tag: (identifier) @tag)

(element_expression
  close_tag: (identifier) @tag)

(element_attribute
  name: (identifier) @attribute)

(element_attribute
  value: (string) @string)

; ── Type annotations ──────────────────────────────────────────
(type_name) @type

(type_record
  (type_field
    (identifier) @property))

(type_sum
  (type_name) @type)

(parameter
  type: (type_name) @type)

(let_declaration
  type: (type_name) @type)

(fn_expression
  return_type: (type_name) @type)

; ── Identifiers ───────────────────────────────────────────────
(identifier) @variable
