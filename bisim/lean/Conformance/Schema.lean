import Agentic.Core.Schema.Json

/-!
# Exact conformance representation of schema values

Unlike the user-facing JSON codec, this test-boundary representation is total
and injective on `Schema.El`: rationals travel as numerator/denominator and
records/lists recurse by schema. It is used by `WorldSpec` and trace answers so
conformance never defaults malformed fixtures or collapses semantic values.
-/

namespace Agentic.Core.Schema.Conformance

open Lean (FromJson Json ToJson fromJson? toJson)
open Agentic.Core Schema

mutual
  def encodeShape : (shape : Shape) → shape.El → Json
    | .null, _ => .null
    | .boolean, value => by change Bool at value; exact .bool value
    | .integer, value => by change Int at value; exact toJson value
    | .number, value => by
        change Rat at value
        exact Json.mkObj [("numerator", toJson value.num), ("denominator", toJson value.den)]
    | .string, value => by change String at value; exact .str value
    | .array items, values => by
        change List items.El at values
        exact .arr (values.map (encodeShape items)).toArray
    | .object, _ => Json.mkObj []
    | .property name schema rest, value => by
        change schema.El × rest.El at value
        exact Json.mkObj ((name, encodeShape schema value.1) :: encodeFields rest value.2)
  termination_by shape _ => (sizeOf shape, 1)

  def encodeFields : (shape : Shape) → shape.El → List (String × Json)
    | .null, _ => []
    | .boolean, _ => []
    | .integer, _ => []
    | .number, _ => []
    | .string, _ => []
    | .array _, _ => []
    | .object, _ => []
    | .property name schema rest, value => by
        change schema.El × rest.El at value
        exact (name, encodeShape schema value.1) :: encodeFields rest value.2
  termination_by shape _ => (sizeOf shape, 0)
end

mutual
  def decodeShape : (shape : Shape) → Json → Option shape.El
    | .null, .null => by change Option Unit; exact some ()
    | .null, _ => none
    | .boolean, .bool value => by change Option Bool; exact some value
    | .boolean, _ => none
    | .integer, json => by change Option Int; exact json.getInt?.toOption
    | .number, json => by
        change Option Rat
        let keysExact := match json.getObj?.toOption with
          | none => false
          | some fields =>
              fields.foldl (init := 0) (fun count _ _ => count + 1) == 2 &&
                fields.all (fun name _ => name = "numerator" || name = "denominator")
        let numerator := (json.getObjVal? "numerator").toOption.bind (·.getInt?.toOption)
        let denominator := (json.getObjVal? "denominator").toOption.bind (·.getNat?.toOption)
        exact if keysExact then
          match numerator, denominator with
          | some num, some den =>
              if h : den ≠ 0 then some (Rat.normalize num den h) else none
          | _, _ => none
        else none
    | .string, .str value => by change Option String; exact some value
    | .string, _ => none
    | .array items, .arr values => by
        change Option (List items.El)
        exact values.toList.mapM (decodeShape items)
    | .array _, _ => none
    | .object, json => by
        change Option Unit
        exact if Schema.Json.objectKeysExact .object json then some () else none
    | .property name schema rest, json => by
        change Option (schema.El × rest.El)
        let shape := Shape.property name schema rest
        exact if Schema.Json.objectKeysExact shape json then decodeFields shape json else none
  termination_by shape _ => (sizeOf shape, 1)

  def decodeFields : (shape : Shape) → Json → Option shape.El
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
  termination_by shape _ => (sizeOf shape, 0)
end

/-- One existential schema/value pair in a conformance world. -/
structure Answer where
  schema : Schema
  value : schema.El

instance : ToJson Answer where
  toJson answer :=
    Json.mkObj [("schema", toJson answer.schema), ("value", encodeShape answer.schema.1 answer.value)]

instance : FromJson Answer where
  fromJson? json := do
    let schema : Schema ← fromJson? (← json.getObjVal? "schema")
    match decodeShape schema.1 (← json.getObjVal? "value") with
    | some value => return ⟨schema, value⟩
    | none => throw "schema answer does not match its schema"

/-- Lookup with the equality transport made explicit. -/
def Answer.lookup (answers : List Answer) (schema : Schema) : Option schema.El :=
  match answers.find? (fun answer => answer.schema = schema) with
  | none => none
  | some answer =>
      if h : answer.schema = schema then some (h ▸ answer.value) else none

def Answer.uniqueSchemas : List Answer → Bool
  | [] => true
  | answer :: rest =>
      !(rest.any (fun other => other.schema = answer.schema)) && uniqueSchemas rest

section RepresentationChecks

example : decodeShape .number
    (Json.mkObj [("numerator", 1), ("denominator", toJson (-2 : Int))]) = none := by native_decide
example : decodeShape .number
    (Json.mkObj [("numerator", 1), ("denominator", 2), ("extra", true)]) = none := by native_decide
example : (encodeShape .number (1 / 3 : Rat)).compress ≠
    (encodeShape .number (2 / 3 : Rat)).compress := by native_decide

end RepresentationChecks

end Agentic.Core.Schema.Conformance
