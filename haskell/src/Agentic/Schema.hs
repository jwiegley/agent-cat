{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Agentic.Schema
-- Description : Schema-indexed structured values, independent of serialization.
--
-- The Haskell realization of @Agentic/Core/Schema.lean@. No JSON type or codec
-- appears here: 'SchemaEl' is the semantic structured value, while
-- @Agentic.Schema.Json@ is one representation of it.
module Agentic.Schema
  ( Schema (..),
    Code (..),
    El,
    SchemaEl,
    SCode (..),
    fromSCode,
    SomeCode (..),
    KnownCode (..),
    sameCode,
    defaultEl,

    -- * Schema witnesses
    HasSchema (..),
    KnownSchema (..),
    ObjectTail,
    FreshProperty,
    SchemaWitness,
    SSchema (..),
    withSchema,
    SomeSchema (..),
    SchemaRep (..),
    schemaNull,
    schemaBoolean,
    schemaInteger,
    schemaNumber,
    schemaString,
    schemaArray,
    schemaObject,
    schemaProperty,
    demoteSchema,
    demoteSSchema,
    promoteSchema,
    sameSchema,

    -- * First-order codes
    CodeRep (..),
    codeRep,
    codeName,
    codeOfName,
  )
where

import Agentic.Text (Verdict (Approve))
import Data.Kind (Constraint)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Type.Equality ((:~:) (Refl))
import GHC.TypeLits
  ( ErrorMessage (ShowType, Text, (:<>:)),
    KnownSymbol,
    SomeSymbol (SomeSymbol),
    Symbol,
    TypeError,
    sameSymbol,
    someSymbolVal,
    symbolVal,
  )

-- | The promoted structural schema algebra. 'SchemaObject' is the empty
-- product; 'SchemaProperty' adds one named component to a product tail.
data Schema
  = SchemaNull
  | SchemaBoolean
  | SchemaInteger
  | SchemaNumber
  | SchemaString
  | SchemaArray Schema
  | SchemaObject
  | SchemaProperty Symbol Schema Schema

class ObjectTail (schema :: Schema)
instance ObjectTail 'SchemaObject
instance ObjectTail ('SchemaProperty name field rest)

type family HasProperty (name :: Symbol) (schema :: Schema) :: Bool where
  HasProperty name 'SchemaObject = 'False
  HasProperty name ('SchemaProperty name field rest) = 'True
  HasProperty name ('SchemaProperty other field rest) = HasProperty name rest
  HasProperty name other = 'False

type family RequireFresh (present :: Bool) (name :: Symbol) :: Constraint where
  RequireFresh 'False name = ()
  RequireFresh 'True name =
    TypeError ('Text "schema property is declared twice: " ':<>: 'ShowType name)

type FreshProperty name fields = RequireFresh (HasProperty name fields) name

-- | Answer codes. The schema is part of the structured code's identity.
data Code
  = CodeText
  | CodeVerdict
  | CodeFlag
  | CodeAck
  | CodeStructured Schema

-- | Format-independent interpretation of the schema algebra.
type family SchemaEl (schema :: Schema) where
  SchemaEl 'SchemaNull = ()
  SchemaEl 'SchemaBoolean = Bool
  SchemaEl 'SchemaInteger = Integer
  SchemaEl 'SchemaNumber = Rational
  SchemaEl 'SchemaString = Text
  SchemaEl ('SchemaArray schema) = [SchemaEl schema]
  SchemaEl 'SchemaObject = ()
  SchemaEl ('SchemaProperty name schema rest) = (SchemaEl schema, SchemaEl rest)

-- | The answer family.
type family El (c :: Code) where
  El 'CodeText = Text
  El 'CodeVerdict = Verdict
  El 'CodeFlag = Bool
  El 'CodeAck = ()
  El ('CodeStructured schema) = SchemaEl schema

-- | Singleton schema syntax, kept behind 'SchemaWitness' so only validated
-- shapes become structured answer codes.
data SSchema (schema :: Schema) where
  SSNull :: SSchema 'SchemaNull
  SSBoolean :: SSchema 'SchemaBoolean
  SSInteger :: SSchema 'SchemaInteger
  SSNumber :: SSchema 'SchemaNumber
  SSString :: SSchema 'SchemaString
  SSArray :: SSchema schema -> SSchema ('SchemaArray schema)
  SSObject :: SSchema 'SchemaObject
  SSProperty ::
    (KnownSymbol name) =>
    SSchema fieldSchema ->
    SSchema fields ->
    SSchema ('SchemaProperty name fieldSchema fields)

newtype SchemaWitness schema = SchemaWitness (SSchema schema)

-- | A Haskell type with a structural schema and total conversion to and from
-- its semantic interpretation. Both conversion compositions must be identity.
-- Primitive and list instances are built in; records can derive lawful
-- instances with @Agentic.Schema.TH.deriveSchema@.
class HasSchema value where
  type SchemaOf value :: Schema
  schemaOf :: SchemaWitness (SchemaOf value)
  toSchemaEl :: value -> SchemaEl (SchemaOf value)
  fromSchemaEl :: SchemaEl (SchemaOf value) -> value

class KnownSchema (schema :: Schema) where
  schemaWitness :: SchemaWitness schema

withSchema :: SchemaWitness schema -> (SSchema schema -> result) -> result
withSchema (SchemaWitness schema) f = f schema

data SomeSchema where
  SomeSchema :: SchemaWitness schema -> SomeSchema

-- | Ordinary first-order schema data.
data SchemaRep
  = RepNull
  | RepBoolean
  | RepInteger
  | RepNumber
  | RepString
  | RepArray SchemaRep
  | RepObject
  | RepProperty Text SchemaRep SchemaRep
  deriving (Eq, Ord, Show)

schemaNull :: SchemaWitness 'SchemaNull
schemaNull = SchemaWitness SSNull

schemaBoolean :: SchemaWitness 'SchemaBoolean
schemaBoolean = SchemaWitness SSBoolean

schemaInteger :: SchemaWitness 'SchemaInteger
schemaInteger = SchemaWitness SSInteger

schemaNumber :: SchemaWitness 'SchemaNumber
schemaNumber = SchemaWitness SSNumber

schemaString :: SchemaWitness 'SchemaString
schemaString = SchemaWitness SSString

schemaArray :: SchemaWitness schema -> SchemaWitness ('SchemaArray schema)
schemaArray (SchemaWitness schema) = SchemaWitness (SSArray schema)

schemaObject :: SchemaWitness 'SchemaObject
schemaObject = SchemaWitness SSObject

schemaProperty ::
  forall name fieldSchema fields.
  (KnownSymbol name, ObjectTail fields, FreshProperty name fields) =>
  SchemaWitness fieldSchema ->
  SchemaWitness fields ->
  SchemaWitness ('SchemaProperty name fieldSchema fields)
schemaProperty (SchemaWitness fieldSchema) (SchemaWitness fields) =
  SchemaWitness (SSProperty fieldSchema fields)

-- Runtime promotion starts from untrusted first-order data, so it retains the
-- checked constructor rather than manufacturing static constraints.
schemaPropertyChecked ::
  forall name fieldSchema fields.
  (KnownSymbol name) =>
  SchemaWitness fieldSchema ->
  SchemaWitness fields ->
  Maybe (SchemaWitness ('SchemaProperty name fieldSchema fields))
schemaPropertyChecked (SchemaWitness fieldSchema) restWitness@(SchemaWitness fields)
  | isObjectRep rest && not (hasNameRep name rest) =
      Just (SchemaWitness (SSProperty fieldSchema fields))
  | otherwise = Nothing
  where
    name = T.pack (symbolVal (Proxy @name))
    rest = demoteSchema restWitness

instance KnownSchema 'SchemaNull where schemaWitness = schemaNull
instance KnownSchema 'SchemaBoolean where schemaWitness = schemaBoolean
instance KnownSchema 'SchemaInteger where schemaWitness = schemaInteger
instance KnownSchema 'SchemaNumber where schemaWitness = schemaNumber
instance KnownSchema 'SchemaString where schemaWitness = schemaString
instance KnownSchema schema => KnownSchema ('SchemaArray schema) where
  schemaWitness = schemaArray (schemaWitness @schema)
instance KnownSchema 'SchemaObject where schemaWitness = schemaObject
instance
  ( KnownSymbol name,
    KnownSchema fieldSchema,
    KnownSchema fields,
    ObjectTail fields,
    FreshProperty name fields
  ) =>
  KnownSchema ('SchemaProperty name fieldSchema fields)
  where
  schemaWitness = schemaProperty @name (schemaWitness @fieldSchema) (schemaWitness @fields)

instance HasSchema () where
  type SchemaOf () = 'SchemaNull
  schemaOf = schemaNull
  toSchemaEl = id
  fromSchemaEl = id

instance HasSchema Bool where
  type SchemaOf Bool = 'SchemaBoolean
  schemaOf = schemaBoolean
  toSchemaEl = id
  fromSchemaEl = id

instance HasSchema Integer where
  type SchemaOf Integer = 'SchemaInteger
  schemaOf = schemaInteger
  toSchemaEl = id
  fromSchemaEl = id

instance HasSchema Rational where
  type SchemaOf Rational = 'SchemaNumber
  schemaOf = schemaNumber
  toSchemaEl = id
  fromSchemaEl = id

instance HasSchema Text where
  type SchemaOf Text = 'SchemaString
  schemaOf = schemaString
  toSchemaEl = id
  fromSchemaEl = id

instance HasSchema value => HasSchema [value] where
  type SchemaOf [value] = 'SchemaArray (SchemaOf value)
  schemaOf = schemaArray (schemaOf @value)
  toSchemaEl = map toSchemaEl
  fromSchemaEl = map fromSchemaEl

isObjectRep :: SchemaRep -> Bool
isObjectRep RepObject = True
isObjectRep RepProperty {} = True
isObjectRep _ = False

hasNameRep :: Text -> SchemaRep -> Bool
hasNameRep wanted = \case
  RepProperty name _ rest -> name == wanted || hasNameRep wanted rest
  _ -> False

demoteSchema :: SchemaWitness schema -> SchemaRep
demoteSchema (SchemaWitness schema) = demoteSSchema schema

demoteSSchema :: SSchema schema -> SchemaRep
demoteSSchema = go
  where
    go :: forall s. SSchema s -> SchemaRep
    go SSNull = RepNull
    go SSBoolean = RepBoolean
    go SSInteger = RepInteger
    go SSNumber = RepNumber
    go SSString = RepString
    go (SSArray items) = RepArray (go items)
    go SSObject = RepObject
    go property@(SSProperty (field :: SSchema fieldSchema) (rest :: SSchema fields)) =
      propertyName property field rest

    propertyName ::
      forall name fieldSchema fields.
      (KnownSymbol name) =>
      SSchema ('SchemaProperty name fieldSchema fields) ->
      SSchema fieldSchema ->
      SSchema fields ->
      SchemaRep
    propertyName _ field rest =
      RepProperty
        (T.pack (symbolVal (Proxy @name)))
        (go field)
        (go rest)

promoteSchema :: SchemaRep -> Maybe SomeSchema
promoteSchema = \case
  RepNull -> Just (SomeSchema schemaNull)
  RepBoolean -> Just (SomeSchema schemaBoolean)
  RepInteger -> Just (SomeSchema schemaInteger)
  RepNumber -> Just (SomeSchema schemaNumber)
  RepString -> Just (SomeSchema schemaString)
  RepArray items -> do
    SomeSchema schema <- promoteSchema items
    pure (SomeSchema (schemaArray schema))
  RepObject -> Just (SomeSchema schemaObject)
  RepProperty name field rest -> do
    SomeSchema fieldSchema <- promoteSchema field
    SomeSchema fields <- promoteSchema rest
    case someSymbolVal (T.unpack name) of
      SomeSymbol (_ :: Proxy propertyName) ->
        SomeSchema <$> schemaPropertyChecked @propertyName fieldSchema fields

sameSSchema :: SSchema a -> SSchema b -> Maybe (a :~: b)
sameSSchema SSNull SSNull = Just Refl
sameSSchema SSBoolean SSBoolean = Just Refl
sameSSchema SSInteger SSInteger = Just Refl
sameSSchema SSNumber SSNumber = Just Refl
sameSSchema SSString SSString = Just Refl
sameSSchema (SSArray a) (SSArray b) = do
  Refl <- sameSSchema a b
  pure Refl
sameSSchema SSObject SSObject = Just Refl
sameSSchema (SSProperty @name a as) (SSProperty @name' b bs) = do
  Refl <- sameSymbol (Proxy @name) (Proxy @name')
  Refl <- sameSSchema a b
  Refl <- sameSSchema as bs
  pure Refl
sameSSchema _ _ = Nothing

sameSchema :: SchemaWitness a -> SchemaWitness b -> Maybe (a :~: b)
sameSchema (SchemaWitness a) (SchemaWitness b) = sameSSchema a b

-- | Singleton answer codes.
data SCode (c :: Code) where
  SText :: SCode 'CodeText
  SVerdict :: SCode 'CodeVerdict
  SFlag :: SCode 'CodeFlag
  SAck :: SCode 'CodeAck
  SStructured :: SchemaWitness schema -> SCode ('CodeStructured schema)

class KnownCode (c :: Code) where
  sCode :: SCode c

instance KnownCode 'CodeText where sCode = SText
instance KnownCode 'CodeVerdict where sCode = SVerdict
instance KnownCode 'CodeFlag where sCode = SFlag
instance KnownCode 'CodeAck where sCode = SAck
instance KnownSchema schema => KnownCode ('CodeStructured schema) where
  sCode = SStructured (schemaWitness @schema)

data SomeCode where
  SomeCode :: SCode c -> SomeCode

-- | Fully first-order code data.
data CodeRep
  = RepText
  | RepVerdict
  | RepFlag
  | RepAck
  | RepStructured SchemaRep
  deriving (Eq, Ord, Show)

codeRep :: SomeCode -> CodeRep
codeRep (SomeCode code) = case code of
  SText -> RepText
  SVerdict -> RepVerdict
  SFlag -> RepFlag
  SAck -> RepAck
  SStructured schema -> RepStructured (demoteSchema schema)

instance Eq SomeCode where a == b = codeRep a == codeRep b
instance Ord SomeCode where compare a b = compare (codeRep a) (codeRep b)
instance Show SomeCode where show = show . codeRep

sameCode :: SCode c -> SCode d -> Maybe (c :~: d)
sameCode SText SText = Just Refl
sameCode SVerdict SVerdict = Just Refl
sameCode SFlag SFlag = Just Refl
sameCode SAck SAck = Just Refl
sameCode (SStructured a) (SStructured b) = do
  Refl <- sameSchema a b
  pure Refl
sameCode _ _ = Nothing

fromSCode :: SCode c -> SomeCode
fromSCode = SomeCode

defaultSchemaEl :: SSchema schema -> SchemaEl schema
defaultSchemaEl SSNull = ()
defaultSchemaEl SSBoolean = False
defaultSchemaEl SSInteger = 0
defaultSchemaEl SSNumber = 0
defaultSchemaEl SSString = T.empty
defaultSchemaEl (SSArray _) = []
defaultSchemaEl SSObject = ()
defaultSchemaEl (SSProperty schema rest) =
  (defaultSchemaEl schema, defaultSchemaEl rest)

defaultEl :: SCode c -> El c
defaultEl SText = T.empty
defaultEl SVerdict = Approve
defaultEl SFlag = False
defaultEl SAck = ()
defaultEl (SStructured schema) = case schema of
  SchemaWitness shape -> defaultSchemaEl shape

codeName :: SomeCode -> Text
codeName (SomeCode code) = case code of
  SText -> "text"
  SVerdict -> "verdict"
  SFlag -> "flag"
  SAck -> "receipt"
  SStructured _ -> "structured"

codeOfName :: Text -> Maybe SomeCode
codeOfName = \case
  "text" -> Just (SomeCode SText)
  "verdict" -> Just (SomeCode SVerdict)
  "flag" -> Just (SomeCode SFlag)
  "receipt" -> Just (SomeCode SAck)
  _ -> Nothing
