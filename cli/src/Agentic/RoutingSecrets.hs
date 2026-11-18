{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Delayed environment-secret resolution for the selected version-2 engines.
-- Secret-bearing values deliberately have neither 'Eq' nor 'Show'.
--
-- An engine whose secret environment variable is unset still resolves, with
-- 'resolvedEngineCredentialReady' false, so that inspection can report it.
-- 'requireEngineCredentials' is the launch-time refusal.
module Agentic.RoutingSecrets
  ( SecretValue,
    withSecretValue,
    ResolvedEngineContext,
    resolvedEngineAlias,
    resolvedEngineBackend,
    resolvedEngineChildEnvironment,
    resolvedEngineCredentialReady,
    resolvedEngineCredentialProblem,
    resolvedEngineExecutionFingerprint,
    resolvedEngineCatalogueCredential,
    resolvedEngineEndpointCredential,
    resolveEngineContexts,
    requireEngineCredentials,
  )
where

import Agentic.Acp (ChildEnvironment, explicitChildEnvironmentWithRedactions)
import Agentic.Route (Backend, backendSpelling)
import Agentic.Decisions (Limits (..))
import Agentic.RoutingConfig.V2
import Control.Monad (forM, forM_, unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.List (nub)
import Data.Either (lefts)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

newtype SecretValue = SecretValue Text

withSecretValue :: SecretValue -> (Text -> a) -> a
withSecretValue (SecretValue value) action = action value

data ResolvedEngineContext = ResolvedEngineContext
  { resolvedEngineAlias :: !Text,
    resolvedEngineBackend :: !Backend,
    resolvedEngineChildEnvironment :: !ChildEnvironment,
    resolvedEngineCredentialReady :: !Bool,
    -- | Why the engine is not credential-ready: the first unset secret.
    resolvedEngineCredentialProblem :: !(Maybe Text),
    resolvedEngineExecutionFingerprint :: !Text,
    resolvedEngineCatalogueCredential :: !(Maybe SecretValue),
    -- | The secret of a decisions endpoint's authentication header.
    resolvedEngineEndpointCredential :: !(Maybe SecretValue)
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
    bindingResults <- traverse (resolveBinding config personaName alias ambient) (engineEnvironment engine)
    credentialResult <- traverse (resolveCatalogueCredential config personaName alias ambient) (engineCatalogue engine >>= catalogueAuth)
    endpointResult <- traverse (resolveCatalogueCredential config personaName alias ambient) (engineEndpoint engine >>= endpointAuth)
    let unset =
          lefts (Map.elems bindingResults)
            <> maybe [] (either pure (const [])) credentialResult
            <> maybe [] (either pure (const [])) endpointResult
        credential = credentialResult >>= either (const Nothing) Just
        selectedBindings = Map.fromList [(T.unpack name, value) | (name, Right value) <- Map.toList bindingResults]
        redactions =
          [ T.pack value
            | (destination, EnvironmentSecret _) <- Map.toList (engineEnvironment engine),
              Just value <- [Map.lookup (T.unpack destination) selectedBindings]
          ]
        child = explicitChildEnvironmentWithRedactions (Map.toList (selectedBindings `Map.union` scrubbed)) redactions
    pure
      ( alias,
        ResolvedEngineContext
          { resolvedEngineAlias = alias,
            resolvedEngineBackend = engineBackend engine,
            resolvedEngineChildEnvironment = child,
            resolvedEngineCredentialReady = null unset,
            resolvedEngineCredentialProblem = case unset of
              problem : _ -> Just problem
              [] -> Nothing,
            resolvedEngineExecutionFingerprint = engineExecutionFingerprint config alias engine,
            resolvedEngineCatalogueCredential = credential,
            resolvedEngineEndpointCredential = endpointResult >>= either (const Nothing) Just
          }
      )
  pure (Map.fromList contexts)

engineExecutionFingerprint :: RoutingConfigV2 -> Text -> EngineDefinition -> Text
engineExecutionFingerprint config alias engine =
  "sha256:" <> T.pack (show (hash bytes :: Digest SHA256))
  where
    bytes =
      BL.toStrict . encode $
        object $
          [ "engine" .= alias,
            "backend" .= backendSpelling (engineBackend engine),
            "provider" .= engineProvider engine,
            "environment"
              .= [ object ["name" .= name, "binding" .= bindingValue binding]
                 | (name, binding) <- Map.toAscList (engineEnvironment engine)
                 ]
          ]
            <> ["session-meta" .= engineSessionMetadata engine | not (Map.null (engineSessionMetadata engine))]
            <> maybe [] (\endpoint -> ["endpoint" .= endpointValue endpoint]) (engineEndpoint engine)
    -- Every non-secret field of a decisions endpoint, and the secret by name
    -- and source, so that a changed endpoint changes the fingerprint.
    endpointValue :: Endpoint -> Value
    endpointValue endpoint =
      object
        [ "url" .= endpointUrl endpoint,
          "auth"
            .= fmap
              ( \auth ->
                  object
                    [ "header" .= catalogueAuthHeader auth,
                      "scheme" .= case catalogueAuthScheme auth of
                        CatalogueAuthRaw -> "raw" :: Text
                        CatalogueAuthBearer -> "bearer",
                      "secret" .= catalogueAuthSecret auth,
                      "source" .= fmap secretEnvironmentName (Map.lookup (catalogueAuthSecret auth) (routingV2Secrets config))
                    ]
              )
              (endpointAuth endpoint),
          "headers" .= Map.toAscList (endpointHeaders endpoint),
          "timeoutMs" .= endpointTimeoutMs endpoint,
          "maxBytes" .= endpointMaxBytes endpoint,
          "limits" .= object ["options" .= limitOptions (endpointLimits endpoint), "levels" .= limitLevels (endpointLimits endpoint)]
        ]
    bindingValue :: EnvironmentBinding -> Value
    bindingValue (EnvironmentValue value) =
      object ["kind" .= ("literal" :: Text), "value" .= value]
    bindingValue (EnvironmentSecret name) =
      object
        [ "kind" .= ("secret" :: Text),
          "name" .= name,
          "source" .= fmap secretEnvironmentName (Map.lookup name (routingV2Secrets config))
        ]

-- | Refuse a launch when one of the named engines has an unset secret. The
-- message names the persona, engine, secret and environment variable.
requireEngineCredentials :: Map Text ResolvedEngineContext -> [Text] -> Either Text ()
requireEngineCredentials contexts aliases =
  case [problem | alias <- nub aliases, Just context <- [Map.lookup alias contexts], Just problem <- [resolvedEngineCredentialProblem context]] of
    problem : _ -> Left problem
    [] -> Right ()

-- The outer 'Either' is a configuration error. The inner 'Left' is an unset
-- secret, which leaves the engine resolved but not credential-ready.
resolveBinding :: RoutingConfigV2 -> Text -> Text -> Map String String -> EnvironmentBinding -> Either Text (Either Text String)
resolveBinding _ _ _ _ (EnvironmentValue value) = Right (Right (T.unpack value))
resolveBinding config personaName engineName ambient (EnvironmentSecret secretName) =
  fmap T.unpack <$> resolveSecret config personaName engineName secretName ambient

resolveCatalogueCredential :: RoutingConfigV2 -> Text -> Text -> Map String String -> CatalogueAuth -> Either Text (Either Text SecretValue)
resolveCatalogueCredential config personaName engineName ambient auth =
  fmap SecretValue <$> resolveSecret config personaName engineName (catalogueAuthSecret auth) ambient

resolveSecret :: RoutingConfigV2 -> Text -> Text -> Text -> Map String String -> Either Text (Either Text Text)
resolveSecret config personaName engineName secretName ambient = do
  reference <-
    maybe
      (Left ("persona '" <> personaName <> "', engine '" <> engineName <> "' requires unknown secret '" <> secretName <> "'"))
      Right
      (Map.lookup secretName (routingV2Secrets config))
  let source = secretEnvironmentName reference
  pure $ case Map.lookup (T.unpack source) ambient of
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
