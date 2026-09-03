import Agentic.Core.Question
import Lean.Data.Json

/-!
# JSON representation of schema-indexed values

This module owns JSON parsing, serialization, and standard JSON Schema
rendering. The semantic `Schema.El` and the workflow calculus do not depend on
it; another representation can be added beside it.
-/

namespace Agentic.Core.Schema.Json

open Lean (FromJson Json JsonNumber ToJson fromJson? toJson)
open Agentic.Core Schema
open Std.Internal.Parsec
open Std.Internal.Parsec.String

deriving instance FromJson, ToJson for Shape

instance : ToJson Schema where
  toJson schema := toJson schema.1

instance : FromJson Schema where
  fromJson? json := do
    let shape : Shape ← fromJson? json
    if h : shape.Valid then return ⟨shape, h⟩
    else throw "schema object tails must be objects and field names must be unique"

instance : ToJson Code where
  toJson
    | .text => "text"
    | .verdict => "verdict"
    | .flag => "flag"
    | .ack => "ack"
    | .structured schema => Json.mkObj [("json", Json.mkObj [("schema", toJson schema)])]

instance : FromJson Code where
  fromJson?
    | .str "text" => return .text
    | .str "verdict" => return .verdict
    | .str "flag" => return .flag
    | .str "ack" => return .ack
    | json => do
        let object ← json.getObj?
        let count := object.foldl (init := 0) (fun n _ _ => n + 1)
        if count ≠ 1 then throw "code must be one constructor"
        let payload ← json.getObjVal? "json"
        let schema : Schema ← fromJson? (← payload.getObjVal? "schema")
        return .structured schema

/-! ## Exact numeric correspondence -/

/-- Largest accepted absolute base-10 exponent. This bounds the amplification
from a short untrusted exponent token to a huge integer. -/
def maxDecimalExponent : Nat := 4096

/-- Check one exponent magnitude without ever materializing its power of ten. -/
def exponentMagnitudeBounded (chars : List Char) : Bool :=
  let digits := match chars with
    | '+' :: rest => rest
    | '-' :: rest => rest
    | rest => rest
  let rec go (value : Nat) : List Char → Bool
    | ch :: rest =>
        if ch.isDigit then
          if value > maxDecimalExponent / 10 then false
          else
            let next := value * 10 + (ch.toNat - '0'.toNat)
            next ≤ maxDecimalExponent && go next rest
        else true
    | [] => true
  go 0 digits

/-- Bound every JSON-number exponent before `Lean.Json.parse`. Lean's parser
materializes positive exponents in `JsonNumber.shiftl`, so checking afterward
is too late for adversarial input. String contents and escapes are skipped. -/
def exponentTokensBounded (text : String) : Bool :=
  let rec go : List Char → Bool → Bool → Bool
    | [], _, _ => true
    | _ :: rest, true, true => go rest true false
    | '\\' :: rest, true, false => go rest true true
    | '"' :: rest, true, false => go rest false false
    | _ :: rest, true, false => go rest true false
    | '"' :: rest, false, _ => go rest true false
    | ch :: rest, false, _ =>
        if ch = 'e' || ch = 'E' then
          exponentMagnitudeBounded rest && go rest false false
        else go rest false false
  go text.toList false false

namespace StrictParser

mutual
  partial def arrayCore (acc : Array Json) : Parser (Array Json) := do
    let head ← anyCore
    let acc := acc.push head
    let ch ← any
    if ch = ']' then
      Std.Internal.Parsec.String.ws
      return acc
    else if ch = ',' then
      Std.Internal.Parsec.String.ws
      arrayCore acc
    else fail "unexpected character in array"

  partial def objectCore (fields : Std.TreeMap.Raw String Json compare) :
      Parser (Std.TreeMap.Raw String Json compare) := do
    Lean.Json.Parser.lookahead (fun ch => ch = '"') "\""
    skip
    let key ← Lean.Json.Parser.str
    if (fields.get? key).isSome then fail s!"duplicate object key: {key}"
    Std.Internal.Parsec.String.ws
    Lean.Json.Parser.lookahead (fun ch => ch = ':') ":"
    skip
    Std.Internal.Parsec.String.ws
    let value ← anyCore
    let ch ← any
    let fields := fields.insert key value
    if ch = '}' then
      Std.Internal.Parsec.String.ws
      return fields
    else if ch = ',' then
      Std.Internal.Parsec.String.ws
      objectCore fields
    else fail "unexpected character in object"

  partial def anyCore : Parser Json := do
    let ch ← peek!
    if ch = '[' then
      skip
      Std.Internal.Parsec.String.ws
      let ch ← peek!
      if ch = ']' then
        skip
        Std.Internal.Parsec.String.ws
        return .arr #[]
      else return .arr (← arrayCore #[])
    else if ch = '{' then
      skip
      Std.Internal.Parsec.String.ws
      let ch ← peek!
      if ch = '}' then
        skip
        Std.Internal.Parsec.String.ws
        return .obj ∅
      else return .obj (← objectCore ∅)
    else if ch = '"' then
      skip
      let value ← Lean.Json.Parser.str
      Std.Internal.Parsec.String.ws
      return .str value
    else if ch = 'f' then
      skipString "false"
      Std.Internal.Parsec.String.ws
      return .bool false
    else if ch = 't' then
      skipString "true"
      Std.Internal.Parsec.String.ws
      return .bool true
    else if ch = 'n' then
      skipString "null"
      Std.Internal.Parsec.String.ws
      return .null
    else if ch = '-' || ('0' ≤ ch && ch ≤ '9') then
      let value ← Lean.Json.Parser.num
      Std.Internal.Parsec.String.ws
      return .num value
    else fail "unexpected input"
end

def any : Parser Json := do
  Std.Internal.Parsec.String.ws
  let value ← anyCore
  eof
  return value

end StrictParser

def strictParse (text : String) : Except String Json :=
  Parser.run StrictParser.any text

/-- A JSON decimal denotes the exact rational `mantissa / 10^exponent`, when
the exponent is within the representation's resource bound. -/
def numberToRat? (number : JsonNumber) : Option Rat :=
  if number.exponent ≤ maxDecimalExponent then
    some <| Rat.normalize number.mantissa (10 ^ number.exponent)
      (Nat.ne_of_gt (Nat.pow_pos (by decide)))
  else none

/-- Remove at most `fuel` factors of `prime`. -/
def factorOut (prime : Nat) : Nat → Nat → Nat × Nat
  | 0, value => (0, value)
  | fuel + 1, value =>
      if value % prime = 0 then
        let (count, rest) := factorOut prime fuel (value / prime)
        (count + 1, rest)
      else (0, value)

/-- Exact finite-decimal realization of a rational, when one exists. -/
def ratToNumber? (number : Rat) : Option JsonNumber :=
  let (twos, afterTwos) := factorOut 2 number.den number.den
  let (fives, rest) := factorOut 5 afterTwos afterTwos
  if rest = 1 then
    let exponent := max twos fives
    if exponent ≤ maxDecimalExponent then
      let multiplier : Nat := 2 ^ (exponent - twos) * 5 ^ (exponent - fives)
      some ⟨number.num * Int.ofNat multiplier, exponent⟩
    else none
  else none

/-! ## Typed value codec -/

private def fieldCount : Shape → Nat
  | .null => 0
  | .boolean => 0
  | .integer => 0
  | .number => 0
  | .string => 0
  | .array _ => 0
  | .object => 0
  | .property _ _ rest => fieldCount rest + 1

def objectKeysExact (shape : Shape) (json : Json) : Bool :=
  match json.getObj?.toOption with
  | none => false
  | some fields =>
      fields.foldl (init := 0) (fun count _ _ => count + 1) == fieldCount shape &&
        fields.all (fun name _ => shape.hasName name)

mutual
  private def decodeShape : (shape : Shape) → Json → Option shape.El
    | .null, .null => by change Option Unit; exact some ()
    | .null, .bool _ => none
    | .null, .num _ => none
    | .null, .str _ => none
    | .null, .arr _ => none
    | .null, .obj _ => none
    | .boolean, .null => none
    | .boolean, .bool value => by change Option Bool; exact some value
    | .boolean, .num _ => none
    | .boolean, .str _ => none
    | .boolean, .arr _ => none
    | .boolean, .obj _ => none
    | .integer, .num value => by
        change Option Int
        exact do
          let rational ← numberToRat? value
          if rational.den = 1 then some rational.num else none
    | .integer, .null => none
    | .integer, .bool _ => none
    | .integer, .str _ => none
    | .integer, .arr _ => none
    | .integer, .obj _ => none
    | .number, .num value => by change Option Rat; exact numberToRat? value
    | .number, .null => none
    | .number, .bool _ => none
    | .number, .str _ => none
    | .number, .arr _ => none
    | .number, .obj _ => none
    | .string, .null => none
    | .string, .bool _ => none
    | .string, .num _ => none
    | .string, .str value => by change Option String; exact some value
    | .string, .arr _ => none
    | .string, .obj _ => none
    | .array _, .null => none
    | .array _, .bool _ => none
    | .array _, .num _ => none
    | .array _, .str _ => none
    | .array items, .arr values => by
        change Option (List items.El)
        exact decodeList items values.toList
    | .array _, .obj _ => none
    | .object, json => by
        change Option Unit
        exact if objectKeysExact .object json then some () else none
    | .property name schema rest, json => by
        change Option (schema.El × rest.El)
        let shape := Shape.property name schema rest
        exact if objectKeysExact shape json then decodeFields shape json else none
  termination_by shape _ => (sizeOf shape, 1, 0)

  private def decodeList (schema : Shape) : List Json → Option (List schema.El)
    | [] => some []
    | value :: rest => return (← decodeShape schema value) :: (← decodeList schema rest)
  termination_by values => (sizeOf schema, 2, values.length)

  private def decodeFields : (shape : Shape) → Json → Option shape.El
    | .null, _ => none
    | .boolean, _ => none
    | .integer, _ => none
    | .number, _ => none
    | .string, _ => none
    | .array _, _ => none
    | .object, _ => by change Option Unit; exact some ()
    | .property name schema rest, json => by
        change Option (schema.El × rest.El)
        match (json.getObjVal? name).toOption with
        | none => exact none
        | some raw => exact return (← decodeShape schema raw, ← decodeFields rest json)
  termination_by shape _ => (sizeOf shape, 0, 0)
end

mutual
  private def encodeShape : (shape : Shape) → shape.El → Option Json
    | .null, _ => some .null
    | .boolean, value => by change Bool at value; exact some (.bool value)
    | .integer, value => by change Int at value; exact some (.num value)
    | .number, value => by change Rat at value; exact Json.num <$> ratToNumber? value
    | .string, value => by change String at value; exact some (.str value)
    | .array items, values => by
        change List items.El at values
        exact (Json.arr ∘ List.toArray) <$> encodeList items values
    | .object, _ => some (Json.mkObj [])
    | .property name schema rest, value => by
        change schema.El × rest.El at value
        exact Json.mkObj <$> encodeFields (.property name schema rest) value
  termination_by shape _ => (sizeOf shape, 1, 0)

  private def encodeList (schema : Shape) : List schema.El → Option (List Json)
    | [] => some []
    | value :: rest => return (← encodeShape schema value) :: (← encodeList schema rest)
  termination_by values => (sizeOf schema, 2, values.length)

  private def encodeFields : (shape : Shape) → shape.El → Option (List (String × Json))
    | .null, _ => none
    | .boolean, _ => none
    | .integer, _ => none
    | .number, _ => none
    | .string, _ => none
    | .array _, _ => none
    | .object, _ => some []
    | .property name schema rest, value => by
        change schema.El × rest.El at value
        exact return (name, ← encodeShape schema value.1) :: (← encodeFields rest value.2)
  termination_by shape _ => (sizeOf shape, 0, 0)
end

def decodeJson (schema : Schema) (json : Json) : Option schema.El :=
  decodeShape schema.1 json

def encode (schema : Schema) (value : schema.El) : Option Json := do
  let json ← encodeShape schema.1 value
  if decodeJson schema json = some value then some json else none

def Representable (schema : Schema) (value : schema.El) : Prop :=
  ∃ json, decodeJson schema json = some value

theorem decodeJson_encode {schema : Schema} {value : schema.El} {json : Json}
    (h : encode schema value = some json) : decodeJson schema json = some value := by
  cases hc : encodeShape schema.1 value with
  | none => simp [encode, hc] at h
  | some candidate =>
      have he : (if decodeJson schema candidate = some value then some candidate else none) =
          some json := by simpa [encode, hc] using h
      by_cases hround : decodeJson schema candidate = some value
      · have hcandidate : candidate = json := by simpa [hround] using he
        subst json
        exact hround
      · simp [hround] at he

theorem representable_of_decode {schema : Schema} {value : schema.El} {json : Json}
    (h : decodeJson schema json = some value) : Representable schema value :=
  ⟨json, h⟩

/-- Parse exactly one JSON value and decode it at `schema`. -/
def decode (schema : Schema) (text : String) : Option schema.El := do
  if !exponentTokensBounded text then none else
    let json ← (strictParse text).toOption
    decodeJson schema json

/-- Compact JSON when this semantic value has a finite JSON realization. -/
def render? (schema : Schema) (value : schema.El) : Option String :=
  (encode schema value).map Json.compress

/-! ## Standard JSON Schema presented to an addressee -/

mutual
  private def schemaJson : Shape → Json
    | .null => Json.mkObj [("type", "null")]
    | .boolean => Json.mkObj [("type", "boolean")]
    | .integer => Json.mkObj [("type", "integer")]
    | .number => Json.mkObj [("type", "number")]
    | .string => Json.mkObj [("type", "string")]
    | .array items => Json.mkObj [("type", "array"), ("items", schemaJson items)]
    | .object =>
        Json.mkObj
          [ ("type", "object")
          , ("properties", Json.mkObj (jsonProperties .object))
          , ("required", toJson (schemaNames .object))
          , ("additionalProperties", false) ]
    | .property name schema rest =>
        let shape := Shape.property name schema rest
        Json.mkObj
          [ ("type", "object")
          , ("properties", Json.mkObj (jsonProperties shape))
          , ("required", toJson (schemaNames shape))
          , ("additionalProperties", false) ]
  termination_by shape => (sizeOf shape, 1)

  private def jsonProperties : Shape → List (String × Json)
    | .null => []
    | .boolean => []
    | .integer => []
    | .number => []
    | .string => []
    | .array _ => []
    | .object => []
    | .property name schema rest => (name, schemaJson schema) :: jsonProperties rest
  termination_by shape => (sizeOf shape, 0)

  private def schemaNames : Shape → List String
    | .null => []
    | .boolean => []
    | .integer => []
    | .number => []
    | .string => []
    | .array _ => []
    | .object => []
    | .property name _ rest => name :: schemaNames rest
  termination_by shape => (sizeOf shape, 0)
end

/-- The standard JSON Schema document for this representation. -/
def schemaDocument (schema : Schema) : Json := schemaJson schema.1

def renderSchema (schema : Schema) : String := (schemaDocument schema).compress

section RepresentationChecks

private def oneFieldShape : Shape := .property "name" .string .object
private def oneFieldSchema : Schema :=
  ⟨oneFieldShape, .property .string .object .object rfl⟩

example : oneFieldSchema.El = (String × Unit) := rfl
example : (encodeShape oneFieldSchema.1 ("Ada", ())).map Json.compress =
    some "{\"name\":\"Ada\"}" := by native_decide
example : decodeShape oneFieldSchema.1 (Json.mkObj [("name", "Ada")]) =
    some ("Ada", ()) := by native_decide
example : decodeShape oneFieldSchema.1 (Json.mkObj []) = none := by native_decide
example : decode oneFieldSchema "{\"name\":\"a\",\"name\":\"b\"}" = none := by native_decide
example : decode oneFieldSchema "{\"name\":\"a\",\"\\u006eame\":\"b\"}" = none := by native_decide
example : ratToNumber? (1 / 2) = some ⟨5, 1⟩ := by native_decide
example : ratToNumber? (1 / 3) = none := by native_decide
example : numberToRat? ⟨1, maxDecimalExponent + 1⟩ = none := by native_decide
example : exponentTokensBounded "1e999999" = false := by native_decide
example : exponentTokensBounded "1e-999999" = false := by native_decide
example : exponentTokensBounded "\"1e999999\"" = true := by native_decide
example : decode Schema.number "1e999999" = none := by native_decide
example : decode Schema.number "1e-999999" = none := by native_decide

end RepresentationChecks

end Agentic.Core.Schema.Json
