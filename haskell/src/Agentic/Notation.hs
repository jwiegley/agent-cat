{-# LANGUAGE TemplateHaskellQuotes #-}

-- |
-- Module      : Agentic.Notation
-- Description : Bare binds: the block's names, taken from the author's binders.
--
-- "Agentic.Workflow" is the surface, and it is complete. Its one visible tax is
-- that a name is written twice —
--
-- > guide <- #guide =: ask (tool "cat") [wf|…|]
--
-- — because the string the /program/ prints has to come from somewhere, and a
-- library cannot read a Haskell binder. This module can: @workflow@ is a
-- Template Haskell splice over a quoted block, and it takes each printed name
-- from the binder that is already there.
--
-- > hardenProgram :: Program
-- > hardenProgram = $(workflow [| do
-- >     guide <- ask (tool "cat") [wf|Write out the house style guide.|]
-- >     …
-- >     result <- revising draft (atMost 2) \patch -> do
-- >         verdict <- panel [ … ]
-- >         amend (ask (model "author") [wf|…{patch}…{verdict}…|])
-- >     caseResult result (\patch -> do … ) stop |])
--
-- __It is a name-injector, not a macro language.__ What it emits is the surface
-- above, unchanged and still exported: @#label@, @'=:'@, 'bindW', 'thenW',
-- 'bindR'. It invents no vocabulary — every function inside the bracket is an
-- ordinary "Agentic.Workflow" export, applied as it is declared — and the
-- @[wf|…|]@ quoter, the @where@-bound @define@s and the type errors of the
-- surface are all exactly what they were. An author who prefers to see the
-- labels writes them, and imports "Agentic.Workflow" directly.
--
-- == The three binding shapes
--
-- A closed set, and it is closed because these are the only places the printed
-- 'Agentic.Raw.Raw' needs a name the author chose:
--
--   1. __a statement bind__, @x <- e@, anywhere in the block including a nested
--      one, which becomes @'bindW' (#x '=:' e) (\\x -> …)@;
--   2. __the carrier lambda of 'revising'__ — @revising subj (atMost n)
--      \\patch -> …@ — whose binder names the carrier, and which regains the
--      @#patch@ argument the surface declares;
--   3. __the settled lambda of 'caseResult'__ — @caseResult result (\\patch ->
--      …) stop@ — whose binder names the settled binding, and which likewise
--      regains its @#patch@ argument.
--
-- Everything else in the bracket is passed through verbatim. The transformer
-- rewrites @do@ (it emits the chain itself, so no @QualifiedDo@ at the use
-- site), and descends only through application and parentheses to find the
-- @do@s that are block arms; it does not look inside a prompt, a panel, a list
-- or a literal, and it does not know what @ask@, @panel@, @amend@, @ifFlag@ or
-- @stop@ are.
--
-- == Where each printed name comes from
--
-- Read against @test\/corpus\/example-000@, whose program is what
-- @Example.Harden@ must keep printing:
--
-- +----------------------------+-------------+--------------------------------+
-- | printed field              | value       | taken from                     |
-- +============================+=============+================================+
-- | @bind.x@                   | @guide@,    | the statement's own binder     |
-- |                            | @draft@,    | (shape 1)                      |
-- |                            | @ok@        |                                |
-- +----------------------------+-------------+--------------------------------+
-- | @bind.x@ of the loop, and  | @result@    | the binder of the statement    |
-- | @caseResult.x@ — one name, |             | that revises (shape 1); the    |
-- | printed twice              |             | scrutinee written at           |
-- |                            |             | @caseResult@ is a /use/ of it  |
-- +----------------------------+-------------+--------------------------------+
-- | @revising.subject@         | @draft@     | the handle passed to           |
-- |                            |             | 'revising', whose symbol is    |
-- |                            |             | the @draft \<-@ binder         |
-- +----------------------------+-------------+--------------------------------+
-- | @revising.carrier@         | @patch@     | the carrier lambda's binder    |
-- |                            |             | (shape 2)                      |
-- +----------------------------+-------------+--------------------------------+
-- | @revising.reviewName@      | @verdict@   | the review's binder inside the |
-- |                            |             | revision block (shape 1)       |
-- +----------------------------+-------------+--------------------------------+
-- | @caseResult.settledName@   | @patch@     | the settled lambda's binder    |
-- |                            |             | (shape 3) — a second binder,   |
-- |                            |             | in a second scope, spelled the |
-- |                            |             | same as the carrier            |
-- +----------------------------+-------------+--------------------------------+
-- | @ifFlag.x@                 | @ok@        | the handle passed to 'ifFlag', |
-- |                            |             | whose symbol is the @ok \<-@   |
-- |                            |             | binder                         |
-- +----------------------------+-------------+--------------------------------+
--
-- So every string in the frozen program is a binder in the source, and the
-- class of bug the labels allowed — @#drafted@ beside a binder called @draft@,
-- which compiles and is caught only by the corpus — has no spelling here.
--
-- == The two names a binder becomes
--
-- A binder inside @[| … |]@ is renamed to a unique before the splice ever sees
-- it, while a @{hole}@ that the @[wf|…|]@ quoter expanded /in/ that bracket
-- stays dynamically bound — 'mkName' @"patch"@, resolved in the ordinary
-- lexical scope at the splice site. The two would not meet, so every rebuilt
-- binder is an as-pattern, @patch_a1B2\@patch@: the unique half receives the
-- uses the author wrote in the bracket, the 'mkName' half receives the uses the
-- quoter wrote, and both are the same value. That is also why an authoring
-- module needs @-Wno-unused-matches@: a binding read only by a @{hole}@ looks
-- unused to the renamer that walks the bracket.
--
-- == What it refuses
--
-- At splice time, naming the rule: a block that is not a @do@; a statement that
-- is not @x <- e@ or a bare expression; a bind whose pattern is not a plain
-- variable; a revision block that is not one review and then one amendment; a
-- 'revising' or 'caseResult' whose lambda is not @\\name -> …@; a qualified
-- @do@ inside the bracket, which would be a second block grammar in a notation
-- that has one.
module Agentic.Notation
  ( -- * The notation
    workflow,

    -- * The surface it compiles to
    module Agentic.Workflow,
  )
where

import Agentic.Workflow hiding (workflow)
import qualified Agentic.Workflow as Surface
import Language.Haskell.TH
  ( Exp (..),
    Name,
    Pat (..),
    Q,
    Stmt (..),
    mkName,
    nameBase,
  )
import qualified Language.Haskell.TH as TH

-- ---------------------------------------------------------------------------
-- The splice
-- ---------------------------------------------------------------------------

-- | A whole program, from a quoted block whose binders are its names.
--
-- > $(workflow [| do
-- >     guide <- ask (tool "cat") [wf|Write out the house style guide.|]
-- >     ok    <- confirm (person "owner") [wf|Ship it?|]
-- >     ifFlag ok stop stop |])
--
-- is 'Surface.workflow' applied to the block those statements spell in
-- "Agentic.Workflow" — @'bindW' (#guide '=:' ask …) (\\guide -> …)@ — so the
-- program it builds is a program the builder built, and elaboration and
-- printing stay the one proven pairing.
workflow :: Q Exp -> Q Exp
workflow q = do
  e <- q
  b <- wBlock e
  pure (AppE (VarE 'Surface.workflow) b)

-- ---------------------------------------------------------------------------
-- The workflow block
-- ---------------------------------------------------------------------------

-- | The quoted block, as the surface spells it.
wBlock :: Exp -> Q Exp
wBlock e = case strip e of
  DoE Nothing ss -> wStmts ss
  DoE (Just _) _ -> fail qualifiedDo
  _ ->
    fail
      "a workflow is a block: write `$(workflow [| do … |])`, whose statements \
      \are the program's."

-- | The statements of a workflow block, right to left: each one is handed the
-- block that follows it, which is what 'bindW' and 'thenW' already expect.
wStmts :: [Stmt] -> Q Exp
wStmts [] = fail endsInTerminal
wStmts [NoBindS e] = wExp e
wStmts (NoBindS e : rest) = do
  e' <- wExp e
  r <- wStmts rest
  pure (AppE (AppE (VarE 'thenW) e') r)
wStmts (BindS p rhs : rest) = do
  n <- binder "a statement of a workflow block" p
  rhs' <- wExp rhs
  r <- wStmts rest
  pure (AppE (AppE (VarE 'bindW) (named n rhs')) (LamE [asBinder n] r))
wStmts (s : _) = fail (badStmt s)

-- | An expression in statement position, or on the right of a bind.
--
-- The two named shapes are the two statements whose lambdas carry a name;
-- everything else is descended through, or left alone.
wExp :: Exp -> Q Exp
wExp e = case spine e of
  (VarE f, [subj, bound, clauses])
    | nameBase f == "revising" -> wRevising subj bound clauses
  (VarE f, [scrutinee, settled, unsettled])
    | nameBase f == "caseResult" -> wCaseResult scrutinee settled unsettled
  _ -> case e of
    DoE Nothing ss -> wStmts ss
    DoE (Just _) _ -> fail qualifiedDo
    AppE f a -> AppE <$> wExp f <*> wExp a
    ParensE x -> ParensE <$> wExp x
    _ -> pure e

-- ---------------------------------------------------------------------------
-- The two statements whose lambdas carry a name
-- ---------------------------------------------------------------------------

-- | @revising draft (atMost 2) \\patch -> do …@ — the carrier's label is the
-- lambda's binder, and it goes back where 'revising' declares it, between the
-- subject and the bound.
wRevising :: Exp -> Exp -> Exp -> Q Exp
wRevising subj bound clauses = case strip clauses of
  LamE [p] body -> do
    n <- binder "the carrier of a bounded revision" p
    body' <- rBlock body
    pure
      ( AppE
          (AppE (AppE (AppE (VarE 'revising) subj) (label n)) bound)
          (LamE [asBinder n] body')
      )
  _ ->
    fail
      "the carrier of a bounded revision is its lambda's binder: write \
      \`revising draft (atMost 2) \\patch -> do …`."

-- | @case result { settled patch { … } unsettled { … } }@ — the settled
-- binding's label is the settled lambda's binder.
--
-- The scrutinee prints nothing: @caseResult.x@ is the name of the /bind/ that
-- revised, and 'revising' is handed it once. It is still typechecked rather
-- than dropped — a revision binds @()@, and the @()@ pattern here is what makes
-- @caseResult result@ a real use of @result@ and @caseResult guide@ a type
-- error.
wCaseResult :: Exp -> Exp -> Exp -> Q Exp
wCaseResult scrutinee settled unsettled = case strip settled of
  LamE [p] body -> do
    n <- binder "the settled arm of a `caseResult`" p
    body' <- wExp body
    unsettled' <- wExp unsettled
    pure
      ( AppE
          ( LamE
              [TupP []]
              ( AppE
                  (AppE (AppE (VarE 'caseResult) (label n)) (LamE [asBinder n] body'))
                  unsettled'
              )
          )
          scrutinee
      )
  _ ->
    fail
      "the settled arm of a `caseResult` is named by its lambda's binder: \
      \write `caseResult result (\\patch -> do …) stop`."

-- ---------------------------------------------------------------------------
-- The revision block
-- ---------------------------------------------------------------------------

-- | A bounded revision reviews once and amends once, which is the whole
-- grammar — the same two statements "Agentic.Workflow.Revision" accepts, and
-- the same refusal for anything else.
rBlock :: Exp -> Q Exp
rBlock e = case strip e of
  DoE Nothing [BindS p review, NoBindS amendment] -> do
    n <- binder "the review of a bounded revision" p
    pure (AppE (AppE (VarE 'bindR) (named n review)) (LamE [asBinder n] amendment))
  DoE _ _ -> fail reviewsThenAmends
  other -> pure other

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------

-- | The binder of a statement, which is the name the program prints.
binder :: String -> Pat -> Q Name
binder what p = case p of
  VarP n -> pure n
  _ ->
    fail
      ( what
          ++ " is named by a plain binder — `x <- …` — because that name is \
             \what the program prints."
      )

-- | @#x@, at the name the author wrote.
label :: Name -> Exp
label n = LabelE (nameBase n)

-- | @#x =: e@.
named :: Name -> Exp -> Exp
named n e = AppE (AppE (VarE '(=:)) (label n)) e

-- | @x_a1B2\@x@ — the bracket's renamed binder, and the plain name a @{hole}@
-- expanded inside the bracket is still looking for. One value, two ways in.
asBinder :: Name -> Pat
asBinder n = AsP n (VarP (mkName (nameBase n)))

-- | Parentheses are not structure.
strip :: Exp -> Exp
strip (ParensE e) = strip e
strip e = e

-- | An application, head first.
spine :: Exp -> (Exp, [Exp])
spine = go []
  where
    go acc e = case strip e of
      AppE f a -> go (strip a : acc) f
      h -> (h, acc)

-- ---------------------------------------------------------------------------
-- The refusals
-- ---------------------------------------------------------------------------

endsInTerminal :: String
endsInTerminal =
  "a workflow block ends in a terminal — `stop`, `ifFlag` or a `case` — and an \
  \empty block ends in nothing."

qualifiedDo :: String
qualifiedDo =
  "a plain `do` is the whole notation: `$(workflow [| … |])` writes the block's \
  \binds itself, so a qualified `do` inside the bracket has nothing to qualify."

reviewsThenAmends :: String
reviewsThenAmends =
  "a bounded revision reviews first — `verdict <- panel […]` — and then amends, \
  \and has no other statement."

badStmt :: Stmt -> String
badStmt s =
  "a workflow block is statements — `x <- question`, or an expression on its \
  \own line. This is neither: "
    ++ TH.pprint s
