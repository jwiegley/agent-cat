{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Delayed environment-secret resolution for the selected version-2 engines.
-- Secret-bearing values deliberately have neither 'Eq' nor 'Show'.
module Agentic.RoutingSecrets
  ( SecretValue,
    withSecretValue,
    ResolvedEngineContext,
    resolvedEngineBackend,
    resolvedEngineChildEnvironment,
    resolvedEngineCredentialReady,
    resolvedEngineCatalogueCredential,
    resolveEngineContexts,
  )
where

import Agentic.Acp (ChildEnvironment, explicitChildEnvironment)
import Agentic.Route (Backend)
import Agentic.RoutingConfig.V2
import Control.Monad (forM, forM_, unless)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

newtype SecretValue = SecretValue Text

withSecretValue :: SecretValue -> (Text -> a) -> a
withSecretValue (SecretValue value) action = action value

data ResolvedEngineContext = ResolvedEngineContext
  { resolvedEngineBackend :: !Backend,
    resolvedEngineChildEnvironment :: !ChildEnvironment,
    resolvedEngineCredentialReady :: !Bool,
    resolvedEngineCatalogueCredential :: !(Maybe SecretValue)
  }

resolveEngineContexts :: SelectedRoutingV2 -> [Text] -> Map String String -> Either Text (Map Text ResolvedEngineContext)
resolveEngineContexts selected required ambient = do
  let config = selectedRoutingV2 selected
      persona = selectedPersona selected
      personaName = selectedPersonaName selected
      aliases = nub required
  forM_ aliases $ \alias ->
    unless (alias `elem` personaEngines persona) $
      Left ("engine '" <> alias <> "' is outside persona '" <> personaName <> "'")
  let destinations = concatMap (Map.keys . engineEnvironment) (Map.elems (routingV2Engines config))
      sources = map secretEnvironmentName (Map.elems (routingV2Secrets config))
      scrubbed = foldr (Map.delete . T.unpack) ambient (destinations <> sources)
  contexts <- forM aliases $ \alias -> do
    engine <- maybe (Left ("unknown engine '" <> alias <> "'")) Right (Map.lookup alias (routingV2Engines config))
    bindings <- traverse (resolveBinding config personaName alias ambient) (engineEnvironment engine)
    credential <- traverse (resolveCatalogueCredential config personaName alias ambient) (engineCatalogue engine >>= catalogueAuth)
    let selectedBindings = Map.fromList [(T.unpack name, value) | (name, value) <- Map.toList bindings]
        child = explicitChildEnvironment . Map.toList $ selectedBindings `Map.union` scrubbed
    pure
      ( alias,
        ResolvedEngineContext
          { resolvedEngineBackend = engineBackend engine,
            resolvedEngineChildEnvironment = child,
            resolvedEngineCredentialReady = True,
            resolvedEngineCatalogueCredential = credential
          }
      )
  pure (Map.fromList contexts)

resolveBinding :: RoutingConfigV2 -> Text -> Text -> Map String String -> EnvironmentBinding -> Either Text String
resolveBinding _ _ _ _ (EnvironmentValue value) = Right (T.unpack value)
resolveBinding config personaName engineName ambient (EnvironmentSecret secretName) =
  T.unpack <$> resolveSecret config personaName engineName secretName ambient

resolveCatalogueCredential :: RoutingConfigV2 -> Text -> Text -> Map String String -> CatalogueAuth -> Either Text SecretValue
resolveCatalogueCredential config personaName engineName ambient auth =
  SecretValue <$> resolveSecret config personaName engineName (catalogueAuthSecret auth) ambient

resolveSecret :: RoutingConfigV2 -> Text -> Text -> Text -> Map String String -> Either Text Text
resolveSecret config personaName engineName secretName ambient = do
  reference <-
    maybe
      (Left ("persona '" <> personaName <> "', engine '" <> engineName <> "' requires unknown secret '" <> secretName <> "'"))
      Right
      (Map.lookup secretName (routingV2Secrets config))
  let source = secretEnvironmentName reference
  case Map.lookup (T.unpack source) ambient of
    Just value | not (null value) -> Right (T.pack value)
    _ ->
      Left
        ( "persona '"
            <> personaName
            <> "', engine '"
            <> engineName
            <> "' requires secret '"
            <> secretName
            <> "' from environment variable "
            <> source
            <> ", which is unset"
        )
