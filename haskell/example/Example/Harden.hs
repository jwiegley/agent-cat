-- | The walked examples, rebuilt in the production surface.
--
-- @agent-cat@ ships two programs under @example\/@ that are not corpus
-- fixtures but /prose/: the flagship @harden.wf@, which the language guide
-- walks line by line, and @hello.wf@, the smallest thing that is still a
-- workflow. Both are frozen in the corpus (@example-000@ and @example-001@),
-- and both are rebuilt here in the combinators of "Agentic.Builder" — same
-- discipline as @tier1\/Cases.hs@, whose nineteen entries are the style guide
-- for this module.
--
-- Two callers share these programs, which is the whole reason they live in a
-- module of their own rather than beside the cases:
--
--   * @tier1@ pins them against the frozen entries — printed 'Raw' and whole
--     reply, positions zeroed on both sides;
--   * @agentic-run@ plans, prices and /runs/ them, against a scripted world or
--     against a live @agent-deck@ session.
--
-- The first caller is what makes the second trustworthy: the program the CLI
-- executes is the same value the conformance runner has already held against
-- the oracle, so a run cannot drift from the language.
--
-- == Transcription, not invention
--
-- Each program below is transcribed from its entry's @request.program@ rather
-- than read off the surface source, for the reason @tier1\/Cases.hs@ gives:
-- what the checker sees is the /post-define-expansion/ form, and the two
-- differ in a way that matters to the printed prompt. A @define@ spliced into
-- a prompt contributes __its own chunk__ and is not fused with the literal
-- beside it, so @harden@'s first drafting prompt is three chunks and not one,
-- and @hello@'s two prompts end in a separate @"Reply in one short line."@
-- literal. Writing the surface text as a single 'lit' would render the same
-- string and print a different program.
--
-- Positions are not transcribed: the builder prints @0:0@ everywhere and the
-- comparison zeroes both sides.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Example.Harden
  ( -- * The programs
    hardenProgram,
    helloProgram,

    -- * The registry
    examples,
    lookupExample,
    exampleNames,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)

import Agentic.Builder
  ( Code (..),
    Program,
    act,
    askModel,
    askModelServed,
    askPerson,
    askTool,
    bind,
    hole,
    ifFlag,
    lit,
    one,
    panel,
    program,
    revisingCase,
    stop,
  )

-- ---------------------------------------------------------------------------
-- The defines, once
-- ---------------------------------------------------------------------------

-- $defines
--
-- @harden.wf@ opens with three @define@s. A @define@ is not a binding and
-- reaches no scope: the import walk expands each use into a literal chunk, so
-- what survives into the checked program is the /text/, appearing once per
-- use. These three Haskell bindings are that expansion, named after the
-- defines so that a reader of @harden.wf@ can follow the transcription, and so
-- that the text is written once here as it is written once there.

-- | @define spec = "harden the parser"@.
spec :: Text
spec = "harden the parser"

-- | @define verdictSpec = "Reply with exactly APPROVE if acceptable, or
-- OBJECTION: \<one line\> if not."@ — the format line every reviewer's prompt
-- ends with.
verdictSpec :: Text
verdictSpec =
  "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."

-- | @define flagSpec = "Reply with exactly yes or no."@ — the owner's.
flagSpec :: Text
flagSpec = "Reply with exactly yes or no."

-- ---------------------------------------------------------------------------
-- The flagship
-- ---------------------------------------------------------------------------

-- | @example\/harden.wf@, the flagship: read the house style, draft a patch,
-- review it by a three-model panel under a bounded revision, and — if the
-- owner says so — apply it.
--
-- > define spec        = "harden the parser"
-- > define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
-- > define flagSpec    = "Reply with exactly yes or no."
-- >
-- > workflow {
-- >   guide <- ask tool "cat"
-- >       "Write out the house style guide, at most four short lines."
-- >
-- >   draft <- ask model "author" served by "deep" ```
-- >       Draft a patch satisfying:
-- >       {spec}
-- >       Reply with a unified diff only.
-- >   ```
-- >
-- >   result <- revising draft as patch, at most 2 amendments {
-- >     verdict <- panel, all must approve [
-- >       ask model "reviewer-correct" "{guide}\nIs this patch correct?\n{patch}\n{verdictSpec}",
-- >       ask model "reviewer-secure"  "{guide}\nIs this patch secure?\n{patch}\n{verdictSpec}",
-- >       ask model "reviewer-simple"  "Could this patch be simpler?\n{patch}\n{verdictSpec}"
-- >     ]
-- >     amend patch {
-- >       ask model "author" served by "deep"
-- >         "{guide}\nRevise this patch:\n{patch}\n{verdict}\nReply with the revised diff only."
-- >     }
-- >   }
-- >
-- >   case result {
-- >     settled patch {
-- >       ok <- ask person "owner" "Apply this patch?\n{patch}\n{flagSpec}"
-- >       if ok { ask tool "apply" "Apply:\n{patch}\nWrite the patched file here, then reply DONE." }
-- >       else { stop }
-- >     }
-- >     unsettled { stop }
-- >   }
-- > }
--
-- Level @branch@, size 36, 19 ask nodes, 9 paths folding between 5 and 15.
-- @codes@ is @null@: a program that branches has no single sequence of answer
-- kinds, which is exactly what separates the flagship from 'helloProgram'.
--
-- == What the transcription pins
--
--   * __The carrier and the settled binder share the name @patch@.__ They are
--     different binders in different scopes — the carrier is live inside the
--     loop's two clauses, the settled binder inside the settled arm — and
--     'revisingCase' takes them as two separate symbols, checking each for
--     freshness against the enclosing scope only. Both are fresh against
--     @[draft, guide]@, so the reuse is legal, and it is the one place in the
--     whole corpus where a program leans on that.
--
--   * __The review is a panel__, which no other rebuilt case does: every
--     @revising@ in @tier1\/Cases.hs@ reviews with a single question. A panel
--     in review position elaborates through 'Agentic.Builder.graftForm' rather
--     than as one ask node, and the noncommutative verdict monoid folds its
--     three members right, from the unit.
--
--   * __@guide@ is read from inside the loop.__ Both the first two panel
--     members and the amendment hole a name bound /outside/ the revision, so
--     every round of the unroll re-reads it through the accumulated
--     substitutions — and never re-asks @cat@. That is what keeps the fresh
--     bill honest: 19 ask nodes, one @cat@ question.
--
--   * __@served by \"deep\"@ appears twice__, on the draft and on the
--     amendment, reaching the shape through @atModel@ and leaving the mode
--     axis silent.
hardenProgram :: Program
hardenProgram =
  program [] $
    bind @"guide" @'CodeText
      ( one
          ( askTool
              "cat"
              [lit "Write out the house style guide, at most four short lines."]
          )
      )
      $ bind @"draft" @'CodeText
        ( one
            ( askModelServed
                "author"
                "deep"
                [ lit "Draft a patch satisfying:\n",
                  lit spec,
                  lit "\nReply with a unified diff only."
                ]
            )
        )
      $ revisingCase @"draft" @"patch" @"verdict" @"patch"
        "result"
        2
        Nothing
        ( panel
            ( askModel
                "reviewer-correct"
                [ hole @"guide",
                  lit "\nIs this patch correct?\n",
                  hole @"patch",
                  lit "\n",
                  lit verdictSpec
                ]
                :| [ askModel
                       "reviewer-secure"
                       [ hole @"guide",
                         lit "\nIs this patch secure?\n",
                         hole @"patch",
                         lit "\n",
                         lit verdictSpec
                       ],
                     askModel
                       "reviewer-simple"
                       [ lit "Could this patch be simpler?\n",
                         hole @"patch",
                         lit "\n",
                         lit verdictSpec
                       ]
                   ]
            )
        )
        ( one
            ( askModelServed
                "author"
                "deep"
                [ hole @"guide",
                  lit "\nRevise this patch:\n",
                  hole @"patch",
                  lit "\n",
                  hole @"verdict",
                  lit "\nReply with the revised diff only."
                ]
            )
        )
        ( bind @"ok" @'CodeFlag
            ( one
                ( askPerson
                    "owner"
                    [ lit "Apply this patch?\n",
                      hole @"patch",
                      lit "\n",
                      lit flagSpec
                    ]
                )
            )
            $ ifFlag @"ok"
              ( act
                  ( askTool
                      "apply"
                      [ lit "Apply:\n",
                        hole @"patch",
                        lit "\nWrite the patched file here, then reply DONE."
                      ]
                  )
                  stop
              )
              stop
        )
        stop

-- ---------------------------------------------------------------------------
-- The small one
-- ---------------------------------------------------------------------------

-- | @example\/hello.wf@: two questions and an act.
--
-- > define brief = "Reply in one short line."
-- >
-- > workflow {
-- >   subject <- ask tool "cat"
-- >     "Name one thing worth greeting.\n{brief}"
-- >
-- >   greeting <- ask model "greeter"
-- >     "Write a greeting for this, and nothing else:\n{subject}\n{brief}"
-- >
-- >   ask tool "say"
-- >     "Say it:\n{greeting}"
-- > }
--
-- Level @pipeline@, size 4, one path, @codes [text, text, receipt]@ and both
-- bills 3. It exists so that the CLI has a subject that is not the flagship:
-- no branch, no loop, and a bill the analysis knows exactly rather than
-- bounds — so a scripted run of @hello@ that does not produce exactly three
-- events is wrong for a reason that needs no reading of a lattice.
--
-- @brief@ is a @define@, so it contributes a chunk of its own to each of the
-- first two prompts: @"Name one thing worth greeting.\\n"@ and
-- @"Reply in one short line."@ are two adjacent literals that are __not
-- fused__.
helloProgram :: Program
helloProgram =
  program [] $
    bind @"subject" @'CodeText
      ( one
          ( askTool
              "cat"
              [lit "Name one thing worth greeting.\n", lit brief]
          )
      )
      $ bind @"greeting" @'CodeText
        ( one
            ( askModel
                "greeter"
                [ lit "Write a greeting for this, and nothing else:\n",
                  hole @"subject",
                  lit "\n",
                  lit brief
                ]
            )
        )
      $ act (askTool "say" [lit "Say it:\n", hole @"greeting"])
      $ stop
  where
    -- @define brief = "Reply in one short line."@
    brief :: Text
    brief = "Reply in one short line."

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

-- | The named programs, in the order the CLI lists them. A key here is what
-- @agentic-run plan\/cost\/run@ takes as its @\<example\>@ argument.
examples :: [(Text, Program)]
examples =
  [ ("harden", hardenProgram),
    ("hello", helloProgram)
  ]

-- | The keys of 'examples', for a usage message or an error.
exampleNames :: [Text]
exampleNames = map fst examples

-- | 'examples' as a lookup.
lookupExample :: Text -> Maybe Program
lookupExample n = lookup n examples
