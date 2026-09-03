{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Agentic.Schema.TH
-- Description : Mechanical schema derivation for monomorphic Haskell records.
module Agentic.Schema.TH (deriveSchema) where

import Agentic.Schema
import Control.Monad (unless)
import Language.Haskell.TH

-- | Derive 'HasSchema' for a monomorphic, single-constructor record.
--
-- Each record label becomes a required object property in source order. Field
-- schemas and conversions come from their own 'HasSchema' instances, so the
-- built-in primitives and lists, plus already-derived nested records, compose
-- without more schema syntax. The declaration site enables @DataKinds@,
-- @TemplateHaskell@, @TypeApplications@, @TypeFamilies@, and
-- @UndecidableInstances@.
deriveSchema :: Name -> Q [Dec]
deriveSchema typeName = reify typeName >>= \case
  TyConI (DataD _ declared variables _ constructors _) ->
    deriveRecord declared variables constructors
  TyConI (NewtypeD _ declared variables _ constructor _) ->
    deriveRecord declared variables [constructor]
  _ -> fail "deriveSchema expects a data or newtype declaration"
  where
    deriveRecord declared variables constructors = do
      unless (null variables) $
        fail "deriveSchema currently requires a monomorphic record"
      (constructor, fields) <- case constructors of
        [RecC name fields] -> pure (name, fields)
        [_] -> fail "deriveSchema requires record syntax"
        _ -> fail "deriveSchema requires exactly one constructor"
      hostNames <- traverse (newName . nameBase . fieldName) fields
      semanticNames <- traverse (newName . (<> "El") . nameBase . fieldName) fields
      let target = ConT declared
          schemaType = foldr propertyType (PromotedT 'SchemaObject) fields
          schemaValue = foldr propertyValue (VarE 'schemaObject) fields
          toPattern =
            RecP
              constructor
              (zipWith (\field name -> (fieldName field, VarP name)) fields hostNames)
          toValue = nestedExpression (zipWith fieldToSemantic fields hostNames)
          fromPattern = nestedPattern (map VarP semanticNames)
          fromValue =
            RecConE
              constructor
              (zipWith fieldFromSemantic fields semanticNames)
          schemaEquation =
            TySynInstD
              (TySynEqn Nothing (AppT (ConT ''SchemaOf) target) schemaType)
          methods =
            [ schemaEquation,
              FunD 'schemaOf [Clause [] (NormalB schemaValue) []],
              FunD 'toSchemaEl [Clause [toPattern] (NormalB toValue) []],
              FunD 'fromSchemaEl [Clause [fromPattern] (NormalB fromValue) []]
            ]
      pure [InstanceD Nothing [] (AppT (ConT ''HasSchema) target) methods]

    fieldName (name, _, _) = name

    fieldType (_, _, valueType) = valueType

    propertyType field rest =
      foldl
        AppT
        (PromotedT 'SchemaProperty)
        [ LitT (StrTyLit (nameBase (fieldName field))),
          AppT (ConT ''SchemaOf) (fieldType field),
          rest
        ]

    propertyValue field rest =
      AppE
        ( AppE
            (AppTypeE (VarE 'schemaProperty) (LitT (StrTyLit (nameBase (fieldName field)))))
            (AppTypeE (VarE 'schemaOf) (fieldType field))
        )
        rest

    fieldToSemantic field name =
      AppE (AppTypeE (VarE 'toSchemaEl) (fieldType field)) (VarE name)

    fieldFromSemantic field name =
      ( fieldName field,
        AppE (AppTypeE (VarE 'fromSchemaEl) (fieldType field)) (VarE name)
      )

    nestedExpression = foldr (\value rest -> TupE [Just value, Just rest]) (TupE [])

    nestedPattern = foldr (\value rest -> TupP [value, rest]) (TupP [])
