import Mathlib.Data.Rat.Defs

/-!
# Schema-indexed structured values

`Schema` is a small algebraic universe of structured value types: unit/null,
booleans, integers, exact numbers, strings, homogeneous lists, and closed
records whose fields are all required. A record is `object` for the empty
product and `property name field rest` for one named component followed by the
rest of the product.

This module is the semantic layer. It deliberately contains no JSON type,
parser, printer, or schema document. JSON is one representation of these
values, defined in `Agentic.Core.Schema.Json`; another representation may be
added without changing `Schema.El`, `Code`, worlds, plans, or their theorems.
-/

namespace Agentic.Core

/-- The first-order structural schema algebra. -/
inductive Schema.Shape where
  | null
  | boolean
  | integer
  | number
  | string
  | array (items : Schema.Shape)
  | object
  | property (name : String) (schema : Schema.Shape) (rest : Schema.Shape)
  deriving Repr, DecidableEq, Inhabited

namespace Schema

/-- Does this record schema already declare `wanted`? -/
def Shape.hasName : Shape → String → Bool
  | .null, _ => false
  | .boolean, _ => false
  | .integer, _ => false
  | .number, _ => false
  | .string, _ => false
  | .array _, _ => false
  | .object, _ => false
  | .property name _ rest, wanted => name == wanted || rest.hasName wanted

/-- Evidence that a shape denotes a record field chain. -/
inductive Shape.IsObject : Shape → Prop where
  | object : Shape.IsObject .object
  | property : Shape.IsObject (.property name schema rest)

/-- Canonical schema evidence: children are valid, record tails are records,
and one record does not declare a field name twice. -/
inductive Shape.Valid : Shape → Prop where
  | null : Shape.Valid .null
  | boolean : Shape.Valid .boolean
  | integer : Shape.Valid .integer
  | number : Shape.Valid .number
  | string : Shape.Valid .string
  | array (items : Shape.Valid schema) : Shape.Valid (.array schema)
  | object : Shape.Valid .object
  | property
      (schema : Shape.Valid fieldSchema)
      (rest : Shape.Valid fields)
      (isObject : Shape.IsObject fields)
      (fresh : fields.hasName name = false) :
      Shape.Valid (.property name fieldSchema fields)

/-- Decide record-shape evidence without any partial cast. -/
def Shape.decIsObject : (shape : Shape) → Decidable shape.IsObject
  | .null => isFalse fun h => nomatch h
  | .boolean => isFalse fun h => nomatch h
  | .integer => isFalse fun h => nomatch h
  | .number => isFalse fun h => nomatch h
  | .string => isFalse fun h => nomatch h
  | .array _ => isFalse fun h => nomatch h
  | .object => isTrue .object
  | .property _ _ _ => isTrue .property

/-- Decide canonical-schema evidence by structural recursion. -/
def Shape.decValid : (shape : Shape) → Decidable shape.Valid
  | .null => isTrue .null
  | .boolean => isTrue .boolean
  | .integer => isTrue .integer
  | .number => isTrue .number
  | .string => isTrue .string
  | .array items =>
      match items.decValid with
      | isTrue h => isTrue (.array h)
      | isFalse h => isFalse fun | .array h' => h h'
  | .object => isTrue .object
  | .property name schema rest =>
      match schema.decValid with
      | isFalse h => isFalse fun | .property h' _ _ _ => h h'
      | isTrue schemaValid =>
          match rest.decValid with
          | isFalse h => isFalse fun | .property _ h' _ _ => h h'
          | isTrue restValid =>
              match rest.decIsObject with
              | isFalse h => isFalse fun | .property _ _ h' _ => h h'
              | isTrue restObject =>
                  if h : rest.hasName name = false then
                    isTrue (.property schemaValid restValid restObject h)
                  else
                    isFalse fun | .property _ _ _ fresh => h fresh

instance (shape : Shape) : Decidable shape.IsObject := shape.decIsObject
instance (shape : Shape) : Decidable shape.Valid := shape.decValid

end Schema

/-- A canonical structural schema. -/
def Schema := { shape : Schema.Shape // shape.Valid }

namespace Schema

instance : Inhabited Schema := ⟨⟨.null, .null⟩⟩
deriving instance DecidableEq for Schema
deriving instance Repr for Schema

namespace Shape

/-- The format-independent structured value denoted by a schema shape. -/
def El : Schema.Shape → Type
  | .null => Unit
  | .boolean => Bool
  | .integer => Int
  | .number => Rat
  | .string => String
  | .array items => List (El items)
  | .object => Unit
  | .property _ schema rest => El schema × El rest

/-- Every structural type is inhabited, so total worlds remain ordinary
functions even for schema-indexed questions. -/
def defaultEl : (schema : Schema.Shape) → El schema
  | .null => by change Unit; exact ()
  | .boolean => by change Bool; exact false
  | .integer => by change Int; exact 0
  | .number => by change Rat; exact default
  | .string => by change String; exact ""
  | .array items => by change List (El items); exact []
  | .object => by change Unit; exact ()
  | .property _ schema rest => by
      change El schema × El rest
      exact (defaultEl schema, defaultEl rest)

/-- Decidable equality follows pointwise from the algebra. -/
def decEqEl : (schema : Schema.Shape) → DecidableEq (El schema)
  | .null => by change DecidableEq Unit; infer_instance
  | .boolean => by change DecidableEq Bool; infer_instance
  | .integer => by change DecidableEq Int; infer_instance
  | .number => by change DecidableEq Rat; infer_instance
  | .string => by change DecidableEq String; infer_instance
  | .array items => by
      change DecidableEq (List (El items))
      letI : DecidableEq (El items) := decEqEl items
      infer_instance
  | .object => by change DecidableEq Unit; infer_instance
  | .property _ schema rest => by
      change DecidableEq (El schema × El rest)
      letI : DecidableEq (El schema) := decEqEl schema
      letI : DecidableEq (El rest) := decEqEl rest
      infer_instance

end Shape

/-- The principal structured value type carried by a schema. -/
abbrev El (schema : Schema) : Type := Shape.El schema.1

instance (schema : Schema) : Inhabited schema.El :=
  ⟨Shape.defaultEl schema.1⟩

instance (schema : Schema) : DecidableEq schema.El :=
  Shape.decEqEl schema.1

/-! ## Construction -/

def null : Schema := ⟨.null, .null⟩
def boolean : Schema := ⟨.boolean, .boolean⟩
def integer : Schema := ⟨.integer, .integer⟩
def number : Schema := ⟨.number, .number⟩
def string : Schema := ⟨.string, .string⟩

def array (items : Schema) : Schema := ⟨.array items.1, .array items.2⟩

/-- Build a closed record in declaration order; duplicate names are rejected. -/
def object? (properties : List (String × Schema)) : Option Schema :=
  let shape := properties.foldr
    (fun property rest => .property property.1 property.2.1 rest) Shape.object
  if h : shape.Valid then some ⟨shape, h⟩ else none

end Schema

end Agentic.Core
