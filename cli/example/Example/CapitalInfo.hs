{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

-- |
-- Module      : Example.CapitalInfo
-- Description : The registry half of the @capital@ example: its tools, page and table.
--
-- 'capitalTools' binds the three tool names that "Capital" asks to Haskell
-- functions. A live run calls them in process, in the run's working directory,
-- and a scripted run answers the same questions from 'capitalScript' instead.
module Example.CapitalInfo
  ( capitalBlurb,
    capitalHelp,
    capitalScript,
    capitalTools,
  )
where

import Agentic.Cli (Tool, receiptTool, textTool)
import Agentic.Workflow (wft)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))

-- | @save@ writes its words to @capital.txt@, @shout@ answers its words in
-- upper case, and @announce@ writes its words to @announcement.txt@.
capitalTools :: [(Text, Tool)]
capitalTools =
  [ ("save", receiptTool (\dir words' -> TIO.writeFile (dir </> "capital.txt") words')),
    ("shout", textTool (\_ words' -> pure (T.toUpper words'))),
    ("announce", receiptTool (\dir words' -> TIO.writeFile (dir </> "announcement.txt") words'))
  ]

-- | The canned replies, one per question, keyed by prefix.
capitalScript :: [(Text, Text)]
capitalScript =
  [ ("What is the capital of France?", "Paris"),
    ("Paris", "PARIS"),
    ("Announce this:", "DONE")
  ]

capitalBlurb :: Text
capitalBlurb = "a model's answer saved and transformed by Haskell functions the runner registers"

capitalHelp :: Text
capitalHelp =
  [wft|
  A model names a capital, and three tools that this registry answers in
  process handle the answer. `save` writes it to `capital.txt`, `shout`
  returns it in upper case, and `announce` writes the shouted form to
  `announcement.txt`. The workflow names the tools only. The Haskell
  functions live in the registry, beside this page.

  **Inputs.** none.

  **Transport.** Any model transport answers the one model question. The
  three tools run inside the runner, in the run's working directory, which is
  the scratch directory when an adapter is started. The save is an act, so
  the shout starts only after `capital.txt` is written.

  ```sh
  agentic-run run capital --engine acp --adapter claude --scratch "$PWD"
  ```

  **Rehearsal.** The table answers every question, the tools included, so a
  rehearsal calls no function and writes no file:

  ```sh
  agentic-run run capital --scripted
  ```

  **Caveats.** A tool answered in process is not a backend, so it needs no
  route and no pin. A registered tool answers at one code, and a program that
  asks it at another is refused before the run starts.
  |]
