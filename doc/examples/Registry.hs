{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Cli (Registry (..), Row (..), cliMain)
import Agentic.Workflow (Example (Fixed))
import Hello (helloProgram)

registry :: Registry
registry =
  Registry
    { regBinary = "manual-run",
      regNoun = "workflow",
      regBanner = "inspect and run the manual example",
      regRows =
        [ ( "hello",
            Row
              { rowExample = Fixed helloProgram,
                rowDoc = "ask for a subject, write a greeting, and say it",
                rowHelp = "A deterministic introductory workflow with no inputs.",
                rowScript =
                  [ ("Name one thing worth greeting.", "the sunrise"),
                    ("Write a greeting for this, and nothing else:", "Good morning, sunrise."),
                    ("Say it:", "DONE")
                  ]
              }
          )
        ]
    }

main :: IO ()
main = cliMain registry
