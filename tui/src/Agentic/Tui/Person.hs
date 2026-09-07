{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Secure loading and code-directed encoding for local person questions.
module Agentic.Tui.Person
  ( PersonPrompt (..),
    loadPersonPrompt,
    personAnswerValue,
  )
where

import Agentic.Runtime
  ( OccurrenceId,
    OccurrenceSnapshot (..),
    RunId,
    PrivateRoot,
    privatePathComponents,
    withPrivateDirectoryAt,
    readQuestionArtifactByCodeNameAt,
  )
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- | Exact private prompt plus the public identity needed for one answer control.
data PersonPrompt = PersonPrompt
  { personPromptOccurrence :: !OccurrenceId,
    personPromptCode :: !Text,
    personPromptIntent :: !Text,
    personPromptText :: !Text
  }
  deriving (Eq, Show)

loadPersonPrompt :: PrivateRoot -> FilePath -> RunId -> OccurrenceSnapshot -> IO (Either Text PersonPrompt)
loadPersonPrompt root runtimeDirectory runId occurrence = do
  result <- try @SomeException $ do
    reference <- maybe (ioError (userError "person occurrence has no question reference")) pure (snapshotOccurrencePersonQuestion occurrence)
    components <- privatePathComponents root runtimeDirectory
    (intent, question) <- withPrivateDirectoryAt root components $ \descriptor ->
      readQuestionArtifactByCodeNameAt
        runtimeDirectory
        descriptor
        runId
        (snapshotOccurrenceId occurrence)
        (snapshotOccurrenceCode occurrence)
        reference
    prompt <- case question of
      Object fields -> case KeyMap.lookup "prompt" fields of
        Just (String value) -> pure value
        _ -> ioError (userError "person question prompt is not text")
      _ -> ioError (userError "person question is not an object")
    pure
      PersonPrompt
        { personPromptOccurrence = snapshotOccurrenceId occurrence,
          personPromptCode = snapshotOccurrenceCode occurrence,
          personPromptIntent = intent,
          personPromptText = prompt
        }
  case result of
    Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
    _ -> pure (either (Left . T.pack . displayException) Right result)

-- | Convert an editor value to the JSON answer expected by the public code name.
personAnswerValue :: Text -> Text -> Either Text Value
personAnswerValue code input = case code of
  "text" -> Right (String input)
  "flag" -> case T.toCaseFold (T.strip input) of
    "y" -> Right (Bool True)
    "yes" -> Right (Bool True)
    "true" -> Right (Bool True)
    "n" -> Right (Bool False)
    "no" -> Right (Bool False)
    "false" -> Right (Bool False)
    _ -> Left "a flag answer must be yes, no, true, or false"
  "receipt"
    | T.null (T.strip input) -> Right Null
    | otherwise -> Left "a receipt answer must be empty"
  "verdict" -> jsonAnswer
  "structured" -> jsonAnswer
  _ -> Left ("unsupported person answer code " <> code)
  where
    jsonAnswer =
      if BS.length encoded > 1024 * 1024
        then Left "person answer exceeds 1048576 UTF-8 bytes"
        else either (Left . ("answer is not JSON: " <>) . T.pack) Right (eitherDecodeStrict' encoded)
    encoded = TE.encodeUtf8 input
