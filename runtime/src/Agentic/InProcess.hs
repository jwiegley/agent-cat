{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Agentic.InProcess
-- Description : The layer that answers a named tool with a registered Haskell function.
--
-- A 'Tool' denotes a function from the rendered words of a question to an
-- answer of one code, @Text -> IO (El c)@, read in the run's working directory.
-- 'answeringTools' is a @'WorldIO' -> 'WorldIO'@ layer of the same shape as
-- 'Agentic.Shell.executingWorld'. A question put to @tool i@, where @i@ names
-- a registered tool, is answered by that tool's function, and every other
-- question passes to the world beneath.
--
-- The layer changes no question. The program still says @ask (tool "shout")
-- …@, the printed term and its corpus entry are unchanged, and a pure
-- 'Agentic.World.World' still answers the same question from its answer sheet.
-- Which function answers a tool is a property of the run, supplied by the
-- composition root, in the way that a route is.
--
-- Intent is read from the source position as usual. A tool bound in value
-- position is a consultation, so its answer is reused by bare question. A tool
-- in statement position is an effect: it runs once per occurrence, in the
-- ordered effect lane, and every later question waits for it.
module Agentic.InProcess
  ( Tool (..),
    textTool,
    flagTool,
    receiptTool,
    toolCode,
    codeMismatch,
    answeringTools,
  )
where

import Agentic.Exec
  ( WorldIO (..),
    addresseeWord,
    codeWord,
    withPhysicalAttempt,
  )
import Agentic.Plan
  ( El,
    Q (..),
    Request (..),
    RequestShape (..),
    SCode (SAck, SFlag, SText),
    Shape (shAddressee),
    fromSCode,
  )
import Agentic.Planning (Addressee (AddrTool), SomeCode, sameCode)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Type.Equality ((:~:) (Refl))

-- | A registered tool: the code it answers at, and a function from the run's
-- working directory and the rendered words of a question to the answer.
--
-- The directory is the one 'Agentic.Shell.executingWorld' runs commands in, so
-- that a tool which writes a file writes it where the run's acts and commands
-- do. The words are the prompt after interpolation, exactly as a model or a
-- command would receive them.
data Tool where
  Tool :: SCode c -> (FilePath -> Text -> IO (El c)) -> Tool

-- | A tool that answers text.
textTool :: (FilePath -> Text -> IO Text) -> Tool
textTool = Tool SText

-- | A tool that answers a flag.
flagTool :: (FilePath -> Text -> IO Bool) -> Tool
flagTool = Tool SFlag

-- | A tool that stands in statement position and answers a receipt.
receiptTool :: (FilePath -> Text -> IO ()) -> Tool
receiptTool = Tool SAck

-- | The code a tool answers at.
toolCode :: Tool -> SomeCode
toolCode (Tool c _) = fromSCode c

-- | Answer every question put to a registered tool with its function, and hand
-- every other question to the world beneath.
--
-- The first argument receives one line per call, in the manner of
-- 'Agentic.Shell.shellLog'. A registered tool takes no transport lane, because
-- no backend conversation carries its answer. A question put to a registered
-- tool at a code the tool does not answer abandons the run, because no answer
-- of the asked code exists.
answeringTools :: (Text -> IO ()) -> FilePath -> [(Text, Tool)] -> WorldIO -> WorldIO
answeringTools say dir tools inner =
  WorldIO
    { worldAskIO = \c q -> case registered (qAddressee (reqQuestion q)) of
        Just tool -> answerWith c q tool
        Nothing -> worldAskIO inner c q,
      worldAskAttemptIO = \context c q -> case registered (qAddressee (reqQuestion q)) of
        Just tool ->
          withPhysicalAttempt context (addresseeWord (qAddressee (reqQuestion q))) $
            \_ -> answerWith c q tool
        Nothing -> worldAskAttemptIO inner context c q,
      worldTurnLane = \c shape -> case registered (shAddressee (rsQuestion shape)) of
        Just _ -> Nothing
        Nothing -> worldTurnLane inner c shape
    }
  where
    registered = \case
      AddrTool i -> (,) i <$> lookup i tools
      _ -> Nothing

    answerWith :: forall c. SCode c -> Request c -> (Text, Tool) -> IO (El c)
    answerWith c q (i, Tool c' f) = case sameCode c c' of
      Just Refl -> do
        say
          ( "call "
              <> addresseeWord (qAddressee (reqQuestion q))
              <> " in process (for the "
              <> codeWord (fromSCode c)
              <> " question)"
          )
        f dir (qPrompt (reqQuestion q))
      Nothing -> ioError (userError (T.unpack (codeMismatch i (fromSCode c') (fromSCode c))))

-- | The refusal for a registered tool asked at a code it does not answer.
codeMismatch :: Text -> SomeCode -> SomeCode -> Text
codeMismatch i answers asked =
  "tool `"
    <> i
    <> "` is registered to answer at the "
    <> codeWord answers
    <> " code, and it was asked at the "
    <> codeWord asked
    <> " code. A registered tool answers at one code."
