{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Sanitized routing projections and mechanical v1-to-v2 migration.
module Agentic.RoutingInspect
  ( routingInspectionV1,
    routingInspectionV2,
    renderRoutingInspectionV1,
    renderRoutingInspectionV2,
    resolvedRealizationPolicy,
    personaSelectionSourceName,
    migrateRoutingConfigV1,
  )
where

import Agentic.Route (backendSpelling)
import Agentic.RoutingConfig
  ( LoadedRouting (..),
    Profile (..),
    Realization (..),
    ResolvedRealization (..),
    ResolvedRouting (..),
    Router (..),
    RoutingConfig (..),
    thinkingName,
  )
import Agentic.RoutingConfig.V2
import Agentic.RoutingDiscovery
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString as BS
import Data.List (nub, sortOn)
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Yaml as Yaml

routingInspectionV1 :: LoadedRouting -> Value
routingInspectionV1 loaded =
  object
    [ "version" .= (1 :: Int),
      "sources" .= map T.pack (loadedRoutingSources loaded),
      "routers" .= map routerJson (Map.elems (routingRouters config)),
      "profiles" .= map profileJson (Map.elems (routingProfiles config))
    ]
  where
    config = loadedRouting loaded
    routerJson router =
      object
        [ "name" .= routerName router,
          "backend" .= backendSpelling (routerBackend router),
          "provider" .= routerProvider router
        ]
    profileJson profile =
      object
        [ "name" .= profileName profile,
          "chain" .= map v1RealizationJson (NE.toList (profileChain profile))
        ]

routingInspectionV2 :: LoadedRouting -> SelectedRoutingV2 -> Map Text Bool -> Map Text InventoryResult -> ResolvedRouting -> Value
routingInspectionV2 loaded selected readiness inventories resolved =
  object
    [ "version" .= (2 :: Int),
      "persona"
        .= object
          [ "name" .= selectedPersonaName selected,
            "source" .= personaSelectionSourceName (selectedPersonaSource selected)
          ],
      "availablePersonas" .= Map.keys (routingV2Personas config),
      "availableModels" .= map availableModelJson (personaModels (selectedPersona selected)),
      "sources" .= map T.pack (loadedRoutingSources loaded),
      "engines" .= map engineJson usedEngines,
      "models" .= map modelJson (Map.elems selections),
      "profiles" .= map profileJson profileNames,
      "warnings" .= warnings
    ]
  where
    config = selectedRoutingV2 selected
    targets = Map.elems (resolvedRealizations resolved)
    usedEngines = nub (map (routerName . resolvedRouter) targets)
    selections =
      Map.fromList
        [ (selectedModelAlias selection, selection)
          | target <- targets,
            Just selection <- [resolvedModelSelection target]
        ]
    profileNames = nub (map resolvedProfile targets)
    warnings =
      nub
        ( catMaybes (map selectedModelWarning (Map.elems selections))
            <> [ "model alias '" <> selectedModelAlias selection <> "' is static-unverified"
                 | selection <- Map.elems selections,
                   selectedModelSource selection == ModelStaticUnverified
               ]
        )

    availableModelJson alias = case Map.lookup alias (routingV2Models config) of
      Nothing -> object ["alias" .= alias]
      Just model -> object ["alias" .= alias, "engine" .= concreteModelEngine model]

    engineJson name = case Map.lookup name (routingV2Engines config) of
      Nothing -> object ["name" .= name, "status" .= ("invalid" :: Text)]
      Just engine ->
        object
          [ "name" .= name,
            "backend" .= backendSpelling (engineBackend engine),
            "provider" .= engineProvider engine,
            "fingerprint" .= engineDefinitionFingerprint config name engine,
            "credentialReady" .= Map.findWithDefault False name readiness,
            "catalogue" .= catalogueJson engine (Map.lookup name inventories)
          ]

    catalogueJson engine result = case engineCatalogue engine of
      Nothing -> object ["status" .= ("none" :: Text)]
      Just _ -> case result of
        Nothing -> object ["status" .= ("unavailable" :: Text)]
        Just inventory ->
          object
            [ "status" .= maybe ("unavailable" :: Text) (inventorySourceName . frozenInventorySource) (inventoryResultInventory inventory),
              "fingerprint" .= inventoryResultFingerprint inventory,
              "fetchedAt" .= (frozenInventoryFetchedAt <$> inventoryResultInventory inventory),
              "cacheAgeSeconds" .= (frozenInventoryAgeSeconds <$> inventoryResultInventory inventory),
              "warning" .= inventoryResultWarning inventory
            ]

    modelJson selection =
      object
        [ "alias" .= selectedModelAlias selection,
          "engine" .= selectedModelEngine selection,
          "model" .= selectedModelId selection,
          "selectorIndex" .= selectedModelSelectorIndex selection,
          "selector" .= selectorJson (selectedModelSelector selection),
          "inventory" .= inventoryJson selection
        ]

    profileJson name =
      object
        [ "name" .= name,
          "rungs" .= map resolvedRealizationPolicy (sortOn resolvedRung [target | target <- targets, resolvedProfile target == name])
        ]

renderRoutingInspectionV1 :: LoadedRouting -> Text
renderRoutingInspectionV1 loaded =
  T.unlines
    ( ["routing schema: 1"]
        <> sourceLines
        <> [ "router " <> routerName router <> ": " <> backendSpelling (routerBackend router) <> " (" <> routerProvider router <> ")"
             | router <- Map.elems (routingRouters config)
           ]
        <> [ "profile " <> profileName profile <> ": " <> T.intercalate " -> " (map realizationModel (NE.toList (profileChain profile)))
             | profile <- Map.elems (routingProfiles config)
           ]
    )
  where
    config = loadedRouting loaded
    sourceLines = case loadedRoutingSources loaded of
      [] -> ["sources: none"]
      paths -> ["source: " <> T.pack path | path <- paths]

renderRoutingInspectionV2 :: LoadedRouting -> SelectedRoutingV2 -> ResolvedRouting -> Text
renderRoutingInspectionV2 loaded selected resolved =
  T.unlines
    ( [ "routing schema: 2",
        "persona: " <> selectedPersonaName selected <> " (" <> personaSelectionSourceName (selectedPersonaSource selected) <> ")"
      ]
        <> sourceLines
        <> map targetLine (Map.elems (resolvedRealizations resolved))
        <> warningLines
    )
  where
    sourceLines = ["source: " <> T.pack path | path <- loadedRoutingSources loaded]
    targetLine target = case resolvedModelSelection target of
      Nothing -> resolvedAxis target <> ": unresolved"
      Just selection ->
        resolvedAxis target
          <> ": "
          <> selectedModelAlias selection
          <> " -> "
          <> selectedModelId selection
          <> " on "
          <> routerName (resolvedRouter target)
          <> " ("
          <> modelSelectionSourceName (selectedModelSource selection)
          <> ")"
    warningLines =
      [ "warning: " <> warning
        | target <- Map.elems (resolvedRealizations resolved),
          Just selection <- [resolvedModelSelection target],
          warning <- maybeToList (selectedModelWarning selection)
            <> ["static-unverified exact model" | selectedModelSource selection == ModelStaticUnverified]
      ]

resolvedRealizationPolicy :: ResolvedRealization -> Value
resolvedRealizationPolicy target =
  object
    ( [ "profile" .= resolvedProfile target,
        "axis" .= resolvedAxis target,
        "rung" .= resolvedRung target,
        "backend" .= backendSpelling (resolvedBackend target),
        "router" .= routerName router,
        "provider" .= routerProvider router,
        "model" .= realizationModel spec,
        "thinking" .= thinkingName (realizationThinking spec),
        "maxOutput" .= realizationMaxOutput spec,
        "options" .= realizationOptions spec
      ]
        <> maybe [] (\fingerprint -> ["engineFingerprint" .= fingerprint]) (resolvedEngineFingerprint target)
        <> maybe [] v2Fields (resolvedModelSelection target)
    )
  where
    spec = resolvedSpec target
    router = resolvedRouter target
    v2Fields selection =
      [ "modelAlias" .= selectedModelAlias selection,
        "engine" .= selectedModelEngine selection,
        "selectorIndex" .= selectedModelSelectorIndex selection,
        "selector" .= selectorJson (selectedModelSelector selection),
        "inventory" .= inventoryJson selection
      ]

selectorJson :: ModelSelector -> Value
selectorJson (ModelExact value) = object ["kind" .= ("exact" :: Text), "value" .= value]
selectorJson (ModelPrefix value ordering) =
  object
    [ "kind" .= ("prefix" :: Text),
      "value" .= value,
      "order" .= fmap modelOrderName ordering
    ]

modelOrderName :: ModelOrder -> Text
modelOrderName ModelNewest = "newest"
modelOrderName ModelIdDescending = "id-descending"

inventoryJson :: ResolvedModelSelection -> Value
inventoryJson selection =
  object
    [ "source" .= modelSelectionSourceName (selectedModelSource selection),
      "fingerprint" .= selectedModelFingerprint selection,
      "fetchedAt" .= selectedModelFetchedAt selection,
      "cacheAgeSeconds" .= selectedModelCacheAgeSeconds selection,
      "warning" .= selectedModelWarning selection
    ]

personaSelectionSourceName :: PersonaSelectionSource -> Text
personaSelectionSourceName PersonaFromCommandLine = "command-line"
personaSelectionSourceName PersonaFromEnvironment = "environment"
personaSelectionSourceName PersonaFromProject = "project"
personaSelectionSourceName PersonaFromUserDefault = "user-default"

migrateRoutingConfigV1 :: RoutingConfig -> Either Text BS.ByteString
migrateRoutingConfigV1 config = do
  let output = Yaml.encode document
  _ <- decodeRoutingUserV2 output
  pure output
  where
    profiles = Map.elems (routingProfiles config)
    pairs =
      nub
        [ (realizationRouter realization, realizationModel realization)
          | profile <- profiles,
            realization <- NE.toList (profileChain profile)
        ]
    aliases = Map.fromList [(pair, "model-" <> T.pack (show index)) | (index, pair) <- zip [(1 :: Int) ..] pairs]
    modelAlias pair = fromMaybe (error "migration pair indexed above") (Map.lookup pair aliases)
    document =
      object
        [ "version" .= (2 :: Int),
          "default-persona" .= ("default" :: Text),
          "secrets" .= object [],
          "engines" .= object (map enginePair (Map.elems (routingRouters config))),
          "models" .= object (map modelPair pairs),
          "personas"
            .= object
              [ Key.fromText "default"
                  .= object
                    [ "engines" .= Map.keys (routingRouters config),
                      "models" .= Map.elems aliases,
                      "profiles" .= object (map profilePair profiles)
                    ]
              ]
        ]
    enginePair router =
      Key.fromText (routerName router)
        .= object
          [ "backend" .= backendSpelling (routerBackend router),
            "provider" .= routerProvider router
          ]
    modelPair pair@(router, model) =
      Key.fromText (modelAlias pair)
        .= object
          [ "engine" .= router,
            "select" .= [object ["exact" .= model]]
          ]
    profilePair profile =
      Key.fromText (profileName profile)
        .= object
          [ "chain" .= map migratedRealization (NE.toList (profileChain profile))
          ]
    migratedRealization realization =
      object
        [ "model" .= modelAlias (realizationRouter realization, realizationModel realization),
          "thinking" .= thinkingName (realizationThinking realization),
          "max-output" .= maybe (String "unconstrained") (Number . fromInteger) (realizationMaxOutput realization),
          "options" .= realizationOptions realization
        ]

v1RealizationJson :: Realization -> Value
v1RealizationJson realization =
  object
    [ "router" .= realizationRouter realization,
      "model" .= realizationModel realization,
      "thinking" .= thinkingName (realizationThinking realization),
      "maxOutput" .= realizationMaxOutput realization,
      "options" .= realizationOptions realization
    ]


maybeToList :: Maybe a -> [a]
maybeToList Nothing = []
maybeToList (Just value) = [value]
