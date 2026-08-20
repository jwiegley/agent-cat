-- |
-- Module      : Agentic.Cli
-- Description : The runner, as a function of the registry it serves.
--
-- Four verbs over a table of named programs: 'list' them, 'plan' one, price it,
-- or run it.
--
-- > <binary> list
-- > <binary> plan  NAME [--raw] [--require-pinned]
-- > <binary> cost  NAME
-- > <binary> run   NAME --scripted
-- > <binary> run   NAME --session <id> [--binary PATH] [--poll MS]
-- >                                    [--route NAME=BACKEND]...
-- >                                    [--timeout MS] [--verbose]
-- > <binary> run   NAME --engine acp [--adapter stub|claude|codex|PATH]
-- >                                  [--adapter-arg ARG]... [--scratch DIR]
-- >                                  [--route NAME=BACKEND]...
-- >                                  [--timeout MS] [--verbose]
--
-- @--engine acp --adapter X@ and @--session S@ name a run's __default
-- answerer__, and @--route@ refines it: a run reaches several model backends at
-- once, dispatching each question by the serving model its @served by@ pin
-- names. That is execution policy and nothing below it — @plan@ and @cost@ do
-- not read a route, and a price that varied with a route table would be the
-- first time in this language that who answers changed what a program costs.
-- See "Agentic.Route".
--
-- This module /was/ @run\/Main.hs@, whole. What moved it here is that a second
-- table of named programs now exists — the owner's toolbox in the separate,
-- private @agent-workflows@ repository, a downstream user of this library —
-- and the thing the two products must share is the
-- __CLI__ and not the __registry__:
--
--   * The registry cannot be shared. @haskell\/ci\/examples.sh@ pins @level@,
--     @size@, @askNodes@, @costSummary@ and both bills __by equality__ for
--     every registered program, and says why: "A new program cannot be
--     registered without being priced." That is right for seven fixtures whose
--     numbers are evidence about the language, and wrong for a toolbox whose
--     rubrics are edited on a Tuesday. Fused, a red @ci\/examples.sh@ would stop
--     meaning "the language regressed" and start meaning "a prompt was
--     reworded" — and a gate that fails routinely stops being read.
--
--   * The CLI must be shared. Verb parsing, the three input flags, engine
--     selection, the pinning guard, the chain table, exit codes and the usage
--     text are a thousand lines that know nothing about /which/ programs are
--     registered. Forking them is exactly the drift this repository exists to
--     refuse.
--
-- So the registry becomes a __value__ ('Registry') and the CLI a __function__
-- of it ('cliMain'). @agentic-run@ is @cliMain examplesRegistry@; @wf@ is that
-- same function at @Workflows.Registry@'s @registry@, in @agent-workflows@'
-- @bin\/Main.hs:21@. Two binaries, two registries, two gates, one parser.
--
-- __What the gates hold, and what they do not.__ The extraction did /not/ leave
-- behaviour alone: it __added the @list@ verb__, and the usage grew a line. The
-- three verbs that predate it are what the gates hold unchanged —
-- @ci\/examples.sh@, @ci\/acp.sh@ and @ci\/deck.sh@ drive @plan@, @cost@ and
-- @run@ from outside, so a moved byte of any of them fails these. @list@ is
-- covered by nothing but its own output: no gate types it.
--
-- An example may take __inputs__ — @review-lite@ takes the commit it reviews —
-- and then every verb accepts them, in three spellings:
--
-- > agentic-run plan review-lite --input ./commit.diff
-- > agentic-run cost review-lite --input-file subject=./commit.diff
-- > agentic-run run  review-lite --scripted --input-arg subject='diff --git …'
--
-- An input is a @define@ supplied at run time ('Agentic.Workflow.taking'), so
-- it reaches prompts as data rather than as an answer, and __the folds do not
-- depend on it__: every fold in "Agentic.Plan" is structural over the term and
-- none reads a prompt, so @plan@ and @cost@ answer for a program whose subject
-- is not yet in hand and say on the @inputs@ line that they did. @run@ requires
-- every input.
--
-- @plan@ and @cost@ read the elaborated 'Agentic.Plan.Plan' and say nothing a
-- run could contradict: they are the /static/ folds, decided before anybody is
-- asked anything. @run@ executes, through "Agentic.Exec"'s memoizing
-- interpreter, against one of three answering services — a table of canned
-- replies, a live @agent-deck@ session by way of "Agentic.AgentDeck", or an ACP
-- adapter this process starts and speaks the protocol to ("Agentic.Acp").
--
-- The two live engines differ in who owns the process on the other end, which
-- is the whole of what @--engine@ says: @acp@ starts an adapter of its own and
-- owns the pipe; @deck@ sends into a session somebody else started and is
-- watching. Both end at "Agentic.Exec"'s decode loop, so a run means the same
-- thing either way and fails in the same words.
--
-- __The program is the same value tier1 pins.__ Nothing here rebuilds, adapts
-- or trims a program for execution; @agentic-run run harden@ runs the exact
-- 'Agentic.Builder.Program' that @tier1@ has already held against the frozen
-- corpus entry, print and reply alike. That is what makes a run evidence about
-- the language rather than about this executable.
--
-- == Exit codes
--
-- @0@ a completed run (or a printed plan or price); @1@ a usage error, which
-- includes a program refused by @--require-pinned@ — nothing was started, so
-- nothing is a run failure; @2@ a
-- transport failure — the session is stopped, the binary or the adapter is
-- missing, the turn outran its budget; @3@ a run abandoned over what arrived:
-- an answer "Agentic.Exec" could not read after its re-asks, or (over ACP) a
-- turn that did not complete where an act needed one to. The last two are kept
-- apart because they ask different things of the operator: @2@ is something to
-- fix about the transport, @3@ is something that was said, or not finished
-- being said.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Agentic.Cli
  ( -- * What a CLI is a CLI /of/
    Registry (..),
    Row (..),

    -- * The runner
    cliMain,
  )
where

import Control.Exception (Handler (..), IOException, catches, try)
import Control.Monad (unless)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.List (nub, sort, sortOn, tails)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
-- `text`'s own internal module, for one thing and only in a message: the
-- length of a byte string's longest valid UTF-8 prefix, which is the offset an
-- operator needs to find the byte. `UnicodeException` names the offending
-- *byte* and not where it is, and the accept/reject decision below is
-- `decodeUtf8'`'s alone — this only sharpens the refusal.
import Data.Text.Internal.Encoding (validateUtf8Chunk)
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (showFFloat)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.FilePath ((</>))
import System.IO
  ( BufferMode (LineBuffering),
    hSetBuffering,
    hSetEncoding,
    stderr,
    stdout,
    utf8,
  )
import System.IO.Error (ioeGetErrorString, isUserError)
import Text.Read (readMaybe)

import Agentic.Acp
  ( Acp,
    AcpConfig (..),
    AcpError,
    adapterArgv,
    defaultAcpConfig,
    renderAcpError,
    withAcps,
    worldOfAcp,
  )
import Agentic.AgentDeck
  ( DeckConfig (..),
    DeckError,
    defaultDeckConfig,
    renderDeckError,
    worldOfDeck,
  )
import Agentic.Builder (Program, progPlan, progRawOut)
import Agentic.Chains (servedChains)
import qualified Data.Map.Strict as Map
import Agentic.Exec
  ( WorldIO (WorldIO),
    announcingWorld,
    chainsOf,
    noChains,
    runPlanWith,
    scriptedWorld,
    stderrLog,
  )
import Agentic.Route
  ( Backend (BackendAcp, BackendDeck),
    Routes,
    Scheme (SchemeAcp, SchemeDeck),
    parseRoute,
    routeBackends,
    routeByModel,
    routeDefault,
    routeNamed,
    routedWorld,
    routes,
    schemeOf,
    schemeWord,
  )
import Data.Set (Set)
import qualified Data.Set as Set
import Agentic.Shell
  ( ShellConfig (shellCwd, shellLog, shellTimeoutMs),
    defaultShellConfig,
    executingWorld,
  )
import Agentic.Guards (guardUnpinnedAsk)
import Agentic.Observe (printedValue, render, renderString)
import Agentic.Plan
  ( askNodes,
    codes,
    costM,
    costSummary,
    level,
    levelName,
    size,
  )
import Agentic.Raw (codeName)
import Agentic.Workflow (Example (..), inputNames, supply)
import Agentic.World (Trace, billFresh, billMemo)

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

-- | One registered program, and the two things every verb needs from it beside
-- the program itself.
--
-- The row is the unit, so a program cannot be registered without them. In
-- particular the canned table travels __beside the program__ rather than in a
-- @scriptFor@ dispatch inside the runner, which is "Example.Isaac"'s own
-- argument for @isaacScript@ ("the keys /are/ the prompt defines those programs
-- are written from", so a key is a prefix by construction rather than by
-- proofreading) applied to every registry alike.
data Row = Row
  { -- | the program, or the program of its inputs
    rowExample :: !Example,
    -- | one line, for @list@ and for the usage message
    rowDoc :: !Text,
    -- | the canned replies @--scripted@ answers from, keyed by prefix
    rowScript :: ![(Text, Text)]
  }

-- | What a CLI is a CLI /of/: a name for the binary, a word for what it holds,
-- a banner, and the rows in listing order.
--
-- @regNoun@ is threaded rather than hard-coded because every refusal names it —
-- @no example named \'x\'@ against @no workflow named \'x\'@ — and an operator
-- reading a message about a "workflow" from a binary that only knows examples
-- has been told something false about which table was searched.
data Registry = Registry
  { -- | @\"agentic-run\"@ | @\"wf\"@ — the usage lines and every refusal's prefix
    regBinary :: !Text,
    -- | @\"example\"@ | @\"workflow\"@ — what one row is called
    regNoun :: !Text,
    -- | the one-line banner at the head of the usage message
    regBanner :: !Text,
    -- | the rows, in the order @list@ prints them
    regRows :: ![(Text, Row)]
  }

-- | The registered names, in listing order.
regNames :: Registry -> [Text]
regNames = map fst . regRows

-- | A row by name.
regLookup :: Registry -> Text -> Maybe Row
regLookup reg n = lookup n (regRows reg)

-- ---------------------------------------------------------------------------
-- What was asked for
-- ---------------------------------------------------------------------------

-- | The command line, once it has been understood.
--
-- The trailing 'Bool' on 'Plan' and 'Run' is @--require-pinned@, which is a
-- fact about the /program/ rather than about the verb or the transport, and so
-- is checked in 'withExample' where the program is first in hand — before a
-- plan is printed and before an adapter is started.
--
-- The input flags ride on all three of the program verbs, because @plan --raw@
-- prints prompts and an operator pricing a run wants to price the run they will
-- make.
data Command
  = -- | The registry itself: every name, with its one line.
    List
  | -- | The static folds, the printed program when the first 'Bool', and
    -- @--require-pinned@ in the second.
    Plan !Text !Bool !Bool ![InputFlag]
  | -- | The cost summary and the fold it summarizes.
    Cost !Text ![InputFlag]
  | -- | Execute, against one of the three answering services, under
    -- @--require-pinned@ when the 'Bool'.
    Run !Text !Target !Bool ![InputFlag]

-- | One input flag, as written.
--
-- @--input FILE@ is the common case and takes no @NAME=@, so a path containing
-- @=@ is never misread; the two named forms split on the first @=@, and no
-- declared name contains one.
data InputFlag
  = -- | @--input FILE@ — the sole input, read from a file
    SoleFile !FilePath
  | -- | @--input-file NAME=FILE@
    NamedFile !Text !FilePath
  | -- | @--input-arg NAME=VALUE@
    NamedArg !Text !Text

-- | One of a program's inputs, once the command line has been read: its name,
-- the text it was given (or 'Nothing', which only @plan@ and @cost@ allow),
-- and where that text came from — which is what is printed, never the value,
-- since a value can be a whole diff.
data Given = Given
  { givenName :: !Text,
    givenText :: !(Maybe Text),
    givenWhence :: !Text
  }

-- | Who answers.
--
-- Two arms and not three, and that is the whole of what routing changed here: a
-- live run is a __table of backends__ rather than a choice between two engines,
-- and the run that names one backend is the run whose table has one entry.
-- @--engine acp --adapter X@ and @--session S@ do not become something else;
-- they become the __default route__, with no change in spelling and no change
-- in meaning, and a command line with no @--route@ prints the same header and
-- reaches the same transport it always did.
data Target
  = -- | The canned table of the row's 'rowScript'.
    Scripted
  | -- | Live backends: the default, and the routes that refine it.
    Routed !RunRoutes

-- | A run's answerers, and the knobs that belong to the /run/ rather than to
-- any one of them.
--
-- @--timeout@, @--verbose@, @--scratch@, @--binary@, @--poll@ and
-- @--adapter-arg@ are per-run and apply to every route of the scheme they
-- belong to. Two reasons, and the second is the operative one: a turn budget is
-- a statement about how long /this run/ will wait and not about which provider
-- it waited on; and __a per-route adapter argument is a two-line wrapper
-- script__, because 'adapterArgv' falls through to a bare path for any word it
-- does not know, while a flag is forever.
--
-- The working directory is settled in 'runCmd' and not in the parser, because a
-- run without @--scratch@ makes one — an act may write, and
-- 'Agentic.Acp.permissionByCode' authorizes a tool call in the session's
-- working directory, so a run that had not been given one of its own would be
-- authorizing writes into whatever directory it was started from.
data RunRoutes = RunRoutes
  { -- | The default, and the routes that refine it.
    rrRoutes :: !(Routes Backend),
    -- | @--scratch DIR@, or 'Nothing' for a fresh one.
    rrScratch :: !(Maybe FilePath),
    -- | @--adapter-arg@, in the order given, for every @acp:@ backend.
    rrAdapterArgs :: ![String],
    -- | @--binary PATH@, for every @deck:@ backend.
    rrBinary :: !(Maybe FilePath),
    rrPollMs :: !(Maybe Int),
    rrTimeoutMs :: !(Maybe Int),
    rrVerbose :: !Bool,
    -- | Whether @--adapter@ was /given/, as against left at its default. The
    -- name alone cannot say — @stub@ is both a thing to type and what a silent
    -- command line means — and the run announces the default rather than
    -- taking it silently.
    rrAdapterGiven :: !Bool
  }

-- | The runner, over the registry it serves.
cliMain :: Registry -> IO ()
cliMain reg = do
  -- A run's questions and answers are the output, and they arrive over
  -- minutes; line buffering is what makes them appear as they happen rather
  -- than in a block at the end. UTF-8 explicitly, because an answer can carry
  -- anything and a locale of @C@ would otherwise abort the run on an em dash.
  hSetBuffering stdout LineBuffering
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  args <- map T.pack <$> getArgs
  case parseCommand reg args of
    Left problem -> die reg 1 problem
    Right cmd ->
      execute reg cmd
        `catches` [ Handler $ \(e :: DeckError) -> die reg 2 ("transport: " <> renderDeckError e),
                    Handler $ \(e :: AcpError) -> die reg 2 ("transport: " <> renderAcpError e),
                    Handler $ \(e :: IOError) ->
                      die reg 3 $
                        if isUserError e
                          then T.pack (ioeGetErrorString e)
                          else T.pack (show e)
                  ]

execute :: Registry -> Command -> IO ()
execute reg = \case
  List -> listCmd reg >> exitSuccess
  Plan name raw pinned ins -> withExample reg pinned False noRefusal name ins (planCmd name raw)
  Cost name ins -> withExample reg False False noRefusal name ins (costCmd name)
  Run name target pinned ins ->
    withExample reg pinned True (routeRefusal reg target) name ins (runCmd reg name target)

-- | The verb owes the program no precondition of its own — @plan@ and @cost@,
-- which read no flag that is a claim about the program's text.
noRefusal :: Program -> Maybe Text
noRefusal = const Nothing

-- | __A @--route@ naming a model this program never pins has configured
-- nothing, and its operator believes otherwise.__
--
-- The refusal is defended for the reason 'chooseTarget''s existing refusals
-- are: a flag silently accepted by the transport it means nothing to is a run
-- configured by a line nobody read. The check is cheap and exact —
-- 'servedChains' already returns @primary -> alternates@ for the whole program,
-- and the set of pinnable names is its keys plus every alternate, because an
-- alternate is a model name and is routed like any other.
--
-- The converse is __not__ an error: a pinned model no @--route@ names takes the
-- default, and the header says so. An exhaustive route table would make
-- @--route@ unusable on any program with more than two pins, and the whole
-- point of a default is to be the answer for everything unremarkable.
--
-- An ill-defined chain table is passed over in silence here, because the run is
-- about to refuse it in its own words with the two spellings named — and a
-- table that cannot be built cannot say which models this program pins either.
routeRefusal :: Registry -> Target -> Program -> Maybe Text
routeRefusal _ Scripted _ = Nothing
routeRefusal reg (Routed rr) prog = case servedChains (progRawOut prog) of
  Left _ -> Nothing
  Right t ->
    let pinnable = sort (nub (Map.keys t <> concat (Map.elems t)))
     in listToMaybe
          [ "--route names the model '"
              <> m
              <> "', which this "
              <> regNoun reg
              <> " never pins; "
              <> ( if null pinnable
                     then "it pins no model at all"
                     else "the models it pins are: " <> T.intercalate ", " pinnable
                 )
          | (m, _) <- routeNamed (rrRoutes rr),
            m `notElem` pinnable
          ]

-- | Look the example up, bind its inputs, or fail naming what is wrong — and,
-- under @--require-pinned@, refuse a program that leaves a model ask without a
-- @served by@.
--
-- __The checks run before the verb does__, so a refused program prints no plan,
-- starts no adapter and spends nothing. That is the whole value of an opt-in
-- guard over a program: it is a statement about the text, and the text is
-- available before anybody is asked anything.
--
-- Exit @1@ throughout, with the guard's own words or the input resolution's. It
-- is a usage exit and not a run exit because nothing ran: the operator asked
-- for something this program does not offer, and the way out is another command
-- line.
--
-- The second 'Bool' is whether every input is required, which is @run@ and only
-- @run@: a static fold does not read a prompt (@Plan.hs@'s folds are all
-- @Plan g a -> …@), so @plan@ and @cost@ answer for a program whose subject is
-- not yet in hand and say on the @inputs@ line that they did.
--
-- The third argument is the verb's own precondition on the program's text, and
-- it is here rather than inside the verb for the reason @--require-pinned@ is:
-- a claim the command line makes about a program is checkable the moment the
-- program is in hand, which is before a plan is printed and before an adapter
-- is started. @run@ passes 'routeRefusal'; the two static verbs pass
-- 'noRefusal', because neither reads a flag that is a claim about the text.
withExample ::
  Registry ->
  Bool ->
  Bool ->
  (Program -> Maybe Text) ->
  Text ->
  [InputFlag] ->
  (Program -> [Given] -> IO ()) ->
  IO ()
withExample reg pinned needsAll refuses name ins k = case regLookup reg name of
  Nothing ->
    die reg 1 $
      "no "
        <> regNoun reg
        <> " named '"
        <> name
        <> "'; there is "
        <> T.intercalate " and " (regNames reg)
  Just row -> do
    resolved <- resolveInputs name needsAll (rowExample row) ins
    case resolved of
      Left why -> die reg 1 why
      Right (prog, bs)
        | pinned, Just why <- guardUnpinnedAsk (progRawOut prog) -> die reg 1 ("refused: " <> why)
        | Just why <- refuses prog -> die reg 1 why
        | otherwise -> k prog bs >> exitSuccess

-- ---------------------------------------------------------------------------
-- The inputs
-- ---------------------------------------------------------------------------

-- | Bind a program's inputs from the command line, or say exactly what is
-- wrong with the line.
--
-- Every refusal here is a usage error, and each names the one thing to change.
-- The order is the order an operator meets them: a program that takes nothing,
-- a bare @--input@ where a name is needed, a name the program does not have,
-- a name given twice, a file that will not read, and — at @run@ — an input
-- nobody gave.
resolveInputs ::
  Text ->
  Bool ->
  Example ->
  [InputFlag] ->
  IO (Either Text (Program, [Given]))
resolveInputs name needsAll ex ins = case ex of
  Fixed prog
    | null ins -> pure (Right (prog, []))
    | otherwise -> pure (Left (name <> " takes no input"))
  Needs par -> case traverse (named (inputNames par)) ins of
    Left why -> pure (Left why)
    Right pairs -> case firstDuplicate (map fst pairs) of
      Just n -> pure (Left ("input '" <> n <> "' was given twice"))
      Nothing -> do
        read' <- traverse (\(n, src) -> fmap ((,) n) <$> text src) pairs
        pure $ do
          given <- sequence read'
          bounds <- traverse (bind given) (inputNames par)
          prog <- supply par (map (fromMaybe "" . givenText) bounds)
          pure (prog, bounds)
  where
    -- Which input a flag names. `--input` names one by being the only one.
    named :: [Text] -> InputFlag -> Either Text (Text, InputFlag)
    named ns f = case f of
      SoleFile _ -> case ns of
        [n] -> Right (n, f)
        _ ->
          Left
            ( name
                <> " takes "
                <> tshow (length ns)
                <> (if length ns == 1 then " input (" else " inputs (")
                <> T.intercalate ", " ns
                <> "); name them with --input-arg or --input-file"
            )
      NamedFile n _ -> known ns n f
      NamedArg n _ -> known ns n f

    known ns n f
      | n `elem` ns = Right (n, f)
      | otherwise =
          Left
            ( name
                <> " has no input named '"
                <> n
                <> "'; it takes "
                <> T.intercalate ", " ns
            )

    -- The text, and where it came from. A file's contents are read as UTF-8
    -- and one trailing newline is stripped, so that an input from a file
    -- splices like a define written in the source: `[wf|…|]` produces no
    -- trailing newline either, and a silent blank line in a prompt is the kind
    -- of difference this repository exists to prevent.
    --
    -- The decode is *strict*: a file that is not UTF-8 refuses the run. A
    -- lenient decode would turn each undecodable byte into U+FFFD and carry
    -- on, and the operator would learn nothing — the substitution happens
    -- inside a prompt, which is where this repository is least willing to be
    -- approximate. A binary file given as a subject is a mistake worth
    -- hearing about at the command line rather than in a model's answer.
    text :: InputFlag -> IO (Either Text (Text, Text))
    text = \case
      NamedArg _ v -> pure (Right (v, sizeOf v <> " given with --input-arg"))
      SoleFile p -> ofFile p
      NamedFile _ p -> ofFile p

    ofFile p = do
      got <- try (BS.readFile p)
      pure $ case got :: Either IOException BS.ByteString of
        Left e -> Left ("could not read " <> T.pack p <> ": " <> T.pack (ioeGetErrorString e))
        Right bytes -> case decodeUtf8' bytes of
          Left e ->
            Left
              ( T.pack p
                  <> " is not UTF-8, at byte "
                  <> tshow (fst (validateUtf8Chunk bytes))
                  <> " of "
                  <> tshow (BS.length bytes)
                  <> ": "
                  <> T.pack (show e)
                  <> "; an input is spliced into prompts as text, so bytes that"
                  <> " are not UTF-8 refuse the run"
              )
          Right t ->
            let t' = fromMaybe t (T.stripSuffix "\n" t)
             in Right (t', sizeOf t' <> " from " <> T.pack p)

    bind given n = case lookup n given of
      Just (t, whence) -> Right (Given n (Just t) whence)
      Nothing
        | needsAll -> Left ("run needs every input: '" <> n <> "' was not given")
        | otherwise -> Right (Given n Nothing "")

-- | The first element that appears again later, if one does.
--
-- Two callers who mean the same thing by it: an input named twice on one
-- command line, and a model routed twice. Both are the operator saying two
-- things about one name, and neither has a resolution that would make what they
-- believe about the run true.
firstDuplicate :: (Eq a) => [a] -> Maybe a
firstDuplicate ns = listToMaybe [n | (n, rest) <- zip ns (drop 1 (tails ns)), n `elem` rest]

-- | A text's size in bytes, as an operator reads it.
sizeOf :: Text -> Text
sizeOf t
  | n < 1000 = tshow n <> " B"
  | otherwise = T.pack (showFFloat (Just 1) (fromIntegral n / 1000 :: Double) "") <> " kB"
  where
    n = BS.length (encodeUtf8 t)

-- | The note @plan --raw@ prints above a program some of whose inputs are
-- empty, and nothing at all when every one was given.
emptyNote :: [Given] -> [Text]
emptyNote gs = case [givenName g | g <- gs, givenText g == Nothing] of
  [] -> []
  ns ->
    [ "  note: " <> T.intercalate ", " ns <> " was not given, so the program",
      "  below prints with it empty — which is a different text from the one",
      "  a run would put.",
      ""
    ]

-- | The @inputs@ line: the name, the kind, and where the text came from —
-- never the text, which can be a whole diff.
inputsLine :: Given -> Text
inputsLine b =
  "  inputs    "
    <> givenName b
    <> " (text) "
    <> case givenText b of
      Nothing -> "— not given; the folds below do not depend on it"
      Just _ -> "= " <> givenWhence b

-- ---------------------------------------------------------------------------
-- list
-- ---------------------------------------------------------------------------

-- | The registry, as the operator reads it: one row per name, with its line.
--
-- It falls out of making the registry a value and is worth having on both
-- binaries: a table nobody can print is a table that goes stale, and the
-- toolbox is a table whose whole point is being browsed.
listCmd :: Registry -> IO ()
listCmd reg = do
  say $ regBinary reg <> " — " <> tshow (length rows) <> " registered:"
  say ""
  mapM_ line rows
  where
    rows = regRows reg
    width = maximum (1 : map (T.length . fst) rows)
    line (n, row) = say $ "  " <> T.justifyLeft width ' ' n <> "  " <> rowDoc row

-- ---------------------------------------------------------------------------
-- plan
-- ---------------------------------------------------------------------------

-- | The five static folds the oracle reports, and — with @--raw@ — the program
-- as "Agentic.Builder" prints it.
--
-- Every line here is decided by the elaborated term alone. In particular
-- @askNodes@ counts the ask nodes /written/, which is not what any run will
-- put: a branch is not taken and a loop is unrolled, so the number to compare a
-- run's bill against is the cost fold below and not this one.
planCmd :: Text -> Bool -> Program -> [Given] -> IO ()
planCmd name raw prog gs = do
  say $ name <> ", as elaborated:"
  say ""
  mapM_ (say . inputsLine) gs
  say $ "  level     " <> levelName (level p)
  say $ "  size      " <> tshow (size p)
  say $ "  askNodes  " <> tshow (askNodes p)
  say $ "  codes     " <> renderCodes
  say $ "  cost      " <> renderSummary (costSummary p)
  if raw
    then do
      say ""
      -- The note stands immediately above the program, because a program
      -- printed with an empty subject is a different text from the one that
      -- will run and the operator must not have to infer that.
      mapM_ say (emptyNote gs)
      say "  the program, as the builder prints it:"
      say ""
      say (indentBy 2 (prettyJson 0 (printedValue prog)))
    else say "  (--raw prints the program itself)"
  where
    p = progPlan prog

    -- @null@ and @[]@ are different answers: no single sequence of answer kinds
    -- exists (the program branches), against a program that asks nothing.
    renderCodes = case codes p of
      Nothing -> "(none — the program branches, so no one sequence of answer kinds)"
      Just [] -> "[] (nothing is asked)"
      Just cs -> T.intercalate ", " (map codeName cs)

-- ---------------------------------------------------------------------------
-- cost
-- ---------------------------------------------------------------------------

-- | The cost summary, and the fold it is a summary of.
--
-- @costSummary@ is @(minFold, maxFold, paths)@ over @costM@'s bag of bills:
-- one element per path through the program, each the number of consultations
-- that path pays for. The two bounds are what a run can be held against — a run
-- whose @billFresh@ falls outside them is a run of a different program — and
-- when they coincide the program has one price rather than a range.
--
-- The bag is sorted before it is printed, because a multiset has no order of
-- its own to report; @Explain.leafBills@ sorts the same one for the same
-- reason.
costCmd :: Text -> Program -> [Given] -> IO ()
costCmd name prog gs = do
  say $ name <> ", priced:"
  say ""
  mapM_ (say . inputsLine) gs
  say $ "  costSummary   " <> renderSummary (costSummary p)
  say ""
  case (mn, mx) of
    (Just lo, Just hi)
      | lo == hi ->
          say $
            "  every path consults "
              <> tshow lo
              <> " times, so this program has one price and not a range."
      | otherwise -> do
          say $ "  no path through this program consults fewer than " <> tshow lo <> " addressees,"
          say $ "  and none consults more than " <> tshow hi <> "."
    _ -> say "  the program has no paths, which is a program that cannot be run."
  say ""
  say $ "  the fold, path by path (" <> tshow paths <> " in all):"
  say $ "    " <> T.intercalate ", " (map renderRun (runLengths (sort leaves)))
  where
    p = progPlan prog
    (mn, mx, paths) = costSummary p
    leaves = costM p

    renderRun (n, k)
      | k == (1 :: Int) = tshow n
      | otherwise = tshow n <> " (×" <> tshow k <> ")"

-- | A sorted list as its runs, so nine paths that cost five things do not print
-- as nine fives.
runLengths :: (Eq a) => [a] -> [(a, Int)]
runLengths = foldr step []
  where
    step x ((y, k) : rest) | x == y = (y, k + 1) : rest
    step x acc = (x, 1) : acc

-- | @minFold n, maxFold m, over k paths@ — shared by @plan@ and @cost@ so the
-- two cannot disagree about the same three numbers.
--
-- The bounds are 'Maybe' because a plan can have no paths at all, in which case
-- there is no least and no greatest and saying @0@ would be saying something
-- false about a program that consults nothing.
renderSummary :: (Maybe Integer, Maybe Integer, Integer) -> Text
renderSummary (mn, mx, paths) =
  "minFold "
    <> bound mn
    <> ", maxFold "
    <> bound mx
    <> ", over "
    <> tshow paths
    <> (if paths == 1 then " path" else " paths")
  where
    bound = maybe "—" tshow

-- ---------------------------------------------------------------------------
-- run
-- ---------------------------------------------------------------------------

-- | Execute the program and report what it cost.
--
-- The world is wrapped in 'announcingWorld', so each question that is actually
-- put prints as two lines — the code, the addressee and the prompt on one, the
-- answer on the next. __A memo hit prints nothing__, because nothing was asked:
-- the printed lines are @billMemo@ many, and the trace they summarize is
-- @billFresh@ many. Seeing the two differ is seeing the memo table work.
-- __The executing layer (D5) is composed here and nowhere else__, announcing
-- outermost and executing next, so a @toolExec@ question is answered before
-- either adapter is consulted: neither @sayAcp@ nor @sayDeck@ ever sees one and
-- no @session\/prompt@ carries it. It is __not__ installed under @--scripted@,
-- which keeps that mode's defining property — it reaches nothing and runs
-- nothing — and is why that arm owes the operator a line saying so.
--
-- __The chain table (D6) is built here too__, from the printed program, and an
-- ill-defined one refuses the run before anything is asked. That is a runner
-- precondition and not a language refusal: the program is well-formed and its
-- meaning is unchanged; what is ill-defined is this table.
runCmd :: Registry -> Text -> Target -> Program -> [Given] -> IO ()
runCmd reg name target prog gs = case target of
  Scripted -> do
    say $
      "running "
        <> name
        <> " against the scripted table ("
        <> tshow (length script)
        <> " canned replies)"
    -- Without this line a green `--scripted` run reads as evidence that the
    -- gate passed, which is the same class of mistake D5 exists to fix.
    say
      "  no command was run; every gate in this program was answered from the \
      \table"
    walkWith id (scriptedWorld script)
  Routed rr -> do
    let rs = rrRoutes rr
        backends = routeBackends rs
    -- __The run has a directory of its own exactly when it starts an adapter of
    -- its own__, and there is one of them however many backends there are
    -- (§3.4). Every `acp:` route gets it as its `acpCwd` and `executingWorld`
    -- gets it as its `shellCwd`, because a `toolExec` gate that checked a build
    -- in a directory the act did not write to is a gate that always passes. A
    -- run that is all `deck:` starts nothing and keeps the answer it always
    -- had: this process's directory, which the session need not share.
    --
    -- The obvious objection — concurrent writes from several adapters — does
    -- not arise: `execIn` is a sequential fold, so there is never more than one
    -- turn in flight in a run.
    dir <-
      if any isAcp backends
        then do
          d <- maybe (freshScratch reg) pure (rrScratch rr)
          createDirectoryIfMissing True d
          pure d
        else pure "."
    sayBackends rr dir backends
    -- Startup is __eager__ and the default is first. Eager because the header
    -- must be true before the first question is put — one that promised three
    -- backends and then failed to start the third mid-run would have been a
    -- false statement at the moment it was read — and because it costs nothing:
    -- `session/new` carries no prompt and spends no tokens, and a `deck:` route
    -- holds no connection at all. The default first because every run needs it,
    -- so a run whose default will not start fails before spawning anything
    -- else.
    withAcps [(b, acpConfigFor rr dir w) | b@(BackendAcp w) <- backends] $ \live ->
      walkWith (executingWorld (shellAt dir)) (routedWorld (fmap (worldOf rr dir live) rs))
  where
    -- The canned table is the row's own, which is why `run` looks the row up
    -- again rather than being handed a program: a script that lived anywhere
    -- but beside its program is a script that drifts from it.
    script = maybe [] rowScript (regLookup reg name)

    shellAt :: FilePath -> ShellConfig
    shellAt dir =
      defaultShellConfig
        { shellCwd = dir,
          shellTimeoutMs = 120000,
          shellLog = say . ("  " <>)
        }

    isAcp b = schemeOf b == SchemeAcp

    -- The answering service of one backend. Every backend the table names is in
    -- `live` if it is an `acp:` one, because `live` is keyed by exactly the
    -- `acp:` members of `routeBackends` and `fmap` asks about nothing else; the
    -- fourth case is therefore unreachable, and it is a raising 'WorldIO'
    -- rather than an `error` so that a bug here would be a named run failure at
    -- the question that hit it and not a bottom in the middle of a fold.
    worldOf :: RunRoutes -> FilePath -> [(Backend, Acp)] -> Backend -> WorldIO
    worldOf rr dir live b = case b of
      BackendDeck s -> worldOfDeck (deckConfigFor rr s)
      BackendAcp w -> case lookup b live of
        Just acp -> worldOfAcp (acpConfigFor rr dir w) acp
        Nothing ->
          WorldIO $ \_ _ ->
            ioError (userError ("no connection was made for the backend acp:" <> T.unpack w))

    -- The per-run knobs, applied to a backend of the scheme they belong to.
    -- Nothing new is decided here: `adapterArgv` and `defaultDeckConfig`
    -- already turn a word into a backend.
    acpConfigFor :: RunRoutes -> FilePath -> Text -> AcpConfig
    acpConfigFor rr dir w =
      let base = defaultAcpConfig (adapterArgv w <> rrAdapterArgs rr)
       in base
            { acpCwd = dir,
              acpTurnTimeoutMs = fromMaybe (acpTurnTimeoutMs base) (rrTimeoutMs rr),
              acpVerbose = rrVerbose rr
            }

    deckConfigFor :: RunRoutes -> Text -> DeckConfig
    deckConfigFor rr s =
      let base = defaultDeckConfig s
       in base
            { deckBinary = fromMaybe (deckBinary base) (rrBinary rr),
              deckPollMs = fromMaybe (deckPollMs base) (rrPollMs rr),
              deckTimeoutMs = fromMaybe (deckTimeoutMs base) (rrTimeoutMs rr),
              deckVerbose = rrVerbose rr
            }

    -- The header: *who answers what, under what policy, before a token moves* —
    -- and never a claim that anybody answered anything, which is the trace's to
    -- say and only afterwards.
    --
    -- At one backend it is today's header, word for word, including "every
    -- addressee — model, tool and person — is this one adapter". That sentence
    -- is not a hedge and not a lie: it is a lie when there are two backends and
    -- true when there is one, so the run that names one prints it and the run
    -- that names several prints the table instead.
    sayBackends :: RunRoutes -> FilePath -> [Backend] -> IO ()
    sayBackends rr dir = \case
      [BackendAcp w] -> do
        let cfg = acpConfigFor rr dir w
        say $
          "running "
            <> name
            <> " against the "
            <> w
            <> " adapter: "
            <> T.unwords (map T.pack (acpCommand cfg))
        -- A default that was not typed is announced rather than assumed: `stub`
        -- is both a word an operator can write and what a silent command line
        -- means, and the difference is the difference between a run that
        -- answers itself and one that reaches a real agent.
        unless (rrAdapterGiven rr) $
          say "  no --adapter given, so the stub answers — the same default agent-cat's own CLI takes"
        say $
          "  cwd "
            <> T.pack dir
            <> ", "
            <> tshow (acpTurnTimeoutMs cfg)
            <> "ms to a turn, "
            <> (if acpFreshPerQuestion cfg then "a new session per question" else "one session for the run")
            <> "; every addressee — model, tool and person — is this one adapter"
        say $ "  a `running` tool's command runs in " <> T.pack dir
      [BackendDeck s] -> do
        let cfg = deckConfigFor rr s
        say $ "running " <> name <> " against agent-deck session " <> deckSession cfg
        say $
          "  polling every "
            <> tshow (deckPollMs cfg)
            <> "ms, "
            <> tshow (deckTimeoutMs cfg)
            <> "ms to a turn; every addressee — model, tool and person — is this one session"
        -- The deck engine sends into a session somebody else started, so the
        -- directory a command runs in and the directory that session works in
        -- need not agree. Announce it rather than assume it.
        say
          "  a `running` tool's command runs in this process's directory, which the \
          \deck session — started by somebody else — need not share"
      bs -> sayManyBackends rr dir bs

    -- The table, when there is more than one backend to name. Six things it
    -- owes the operator, each earned: the backends __deduplicated__, so the
    -- count is processes and not route lines; the default named first and what
    -- falls to it said out loud, because the remainder is the part an operator
    -- cannot compute from the flag list; the pinned models this program has
    -- that no route claims, on their own line, so that a mistyped route reads
    -- as a mistyped route and not as an absent one; the working-directory
    -- lines, unchanged because the fact is unchanged; the chain lines, which
    -- `walkWith` prints a moment later and which are more worth printing when a
    -- ladder crosses providers, not less; and no claim that any backend
    -- answered anything.
    sayManyBackends :: RunRoutes -> FilePath -> [Backend] -> IO ()
    sayManyBackends rr dir bs = do
      say $ "running " <> name <> " against " <> tshow (length bs) <> " backends:"
      say $ pad "default" <> backendWords rr (routeDefault (rrRoutes rr))
      say $ pad "" <> "— every unpinned ask, every tool and every person"
      mapM_ route (routeNamed (rrRoutes rr))
      unless (null unclaimed) $
        say $ pad (T.intercalate ", " unclaimed) <> "the default (no --route names them)"
      case [w | BackendAcp w <- bs] of
        [] -> pure ()
        (w : _) ->
          let cfg = acpConfigFor rr dir w
           in say $
                "  cwd "
                  <> T.pack dir
                  <> ", "
                  <> tshow (acpTurnTimeoutMs cfg)
                  <> "ms to a turn, "
                  <> (if acpFreshPerQuestion cfg then "a new session per question" else "one session for the run")
      case [s | BackendDeck s <- bs] of
        [] -> pure ()
        (s : _) ->
          let cfg = deckConfigFor rr s
           in say $
                "  polling every "
                  <> tshow (deckPollMs cfg)
                  <> "ms, "
                  <> tshow (deckTimeoutMs cfg)
                  <> "ms to a turn"
      say $ "  a `running` tool's command runs in " <> T.pack dir
      where
        route (m, b) = do
          say $ pad m <> backendWords rr b
          -- §5.3: the deck arm's directory caveat is per route and not per run,
          -- because with a mixed table it holds of the `deck:` routes and is
          -- false of the `acp:` ones.
          case b of
            BackendDeck _ ->
              say $
                pad ""
                  <> "— its working directory is its own; this run's tools run in "
                  <> T.pack dir
            BackendAcp _ -> pure ()

        -- Every model this program pins — the `served by` primaries and their
        -- spares — that no route claims. `servedChains` has the set in hand;
        -- an ill-defined table is about to be refused by `walkWith` in its own
        -- words, and until then there is nothing honest to print.
        unclaimed =
          [ m
          | m <- either (const []) pinnable (servedChains (progRawOut prog)),
            not (m `Map.member` routeByModel (rrRoutes rr))
          ]
        pinnable t = sort (nub (Map.keys t <> concat (Map.elems t)))

        labels = "default" : map fst (routeNamed (rrRoutes rr)) <> [T.intercalate ", " unclaimed]
        width = maximum (1 : map T.length labels)
        pad l = "  " <> T.justifyLeft (width + 2) ' ' l

    -- How a backend names itself in the header: the words today's one-backend
    -- header uses, so that reading a routed run's table is reading the same
    -- sentence several times.
    backendWords :: RunRoutes -> Backend -> Text
    backendWords rr = \case
      BackendAcp w ->
        "the " <> w <> " adapter: " <> T.unwords (map T.pack (acpCommand (acpConfigFor rr "." w)))
      BackendDeck s -> "agent-deck session " <> s

    walkWith :: (WorldIO -> WorldIO) -> WorldIO -> IO ()
    walkWith exec world = do
      -- The inputs this run's prompts were built from, announced before the
      -- first question: an operator reading a transcript must be able to see
      -- which subject it was about, and the value itself can be a whole diff.
      mapM_ (say . inputsLine) gs
      chains <- case servedChains (progRawOut prog) of
        Left why -> do
          say ("refusing to start: " <> why)
          exitWith (ExitFailure 1)
        Right t
          | Map.null t -> pure noChains
          | otherwise -> do
              mapM_ (say . chainLine) [e | e <- Map.toList t, not (null (snd e))]
              pure (chainsOf stderrLog t)
      say ""
      (_, tr) <-
        runPlanWith
          chains
          (announcingWorld (say . ("  " <>)) (exec world))
          (progPlan prog)
      say ""
      report tr

    chainLine (m, spares) =
      "  "
        <> m
        <> " may be answered instead by "
        <> T.intercalate ", " spares
        <> " — a fail-over is narrated on stderr, and the trace records who answered"

    report :: Trace -> IO ()
    report tr = do
      say "  the run is over."
      say "    answer      () — a workflow's value is the unit; what it did is the trace"
      say $ "    billFresh   " <> tshow (billFresh tr) <> " (consultations the run reached)"
      say $ "    billMemo    " <> tshow (billMemo tr) <> " (distinct questions, which is what was put)"

-- | A directory of this run's own, under the system temporary directory, for a
-- @--engine acp@ run that named none.
--
-- Every run acts somewhere: a workflow may end in an act that writes, and
-- 'Agentic.Acp.permissionByCode' authorizes a tool call /in the session's
-- working directory/. Making one per run is what keeps the answer to "where may
-- this agent write?" from being "wherever you happened to be standing". The name
-- is the registry's binary, for the reason every refusal names it too: a @wf@
-- run whose scratch directory said @agentic-run-@ would name the wrong product.
freshScratch :: Registry -> IO FilePath
freshScratch reg = do
  tmp <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  pure (tmp </> (T.unpack (regBinary reg) <> "-" <> show stamp))

-- ---------------------------------------------------------------------------
-- The command line
-- ---------------------------------------------------------------------------

-- | Parse the arguments, or say what is wrong together with the usage.
parseCommand :: Registry -> [Text] -> Either Text Command
parseCommand reg = \case
  [] -> Left (usage reg)
  ["list"] -> Right List
  ("list" : _) -> Left ("list takes nothing else\n\n" <> usage reg)
  [verb]
    | verb `elem` verbs ->
        Left (verb <> " needs " <> article <> ": " <> T.intercalate " or " (regNames reg))
  ("plan" : name : rest) -> planOpts name False False [] rest
  ("cost" : name : rest) -> costOpts name [] rest
  ("run" : name : rest) -> (\(t, p, ins) -> Run name t p ins) <$> parseTarget reg rest
  (verb : _) -> Left ("no verb '" <> verb <> "'\n\n" <> usage reg)
  where
    verbs = ["plan", "cost", "run"]

    article
      | T.any (`elem` ("aeiou" :: String)) (T.take 1 (regNoun reg)) = "an " <> regNoun reg
      | otherwise = "a " <> regNoun reg

    -- Two independent flags, so they are folded rather than enumerated: the
    -- pair spelled in the other order is the same request.
    planOpts :: Text -> Bool -> Bool -> [InputFlag] -> [Text] -> Either Text Command
    planOpts name raw pinned ins args = case args of
      [] -> Right (Plan name raw pinned ins)
      ("--raw" : more) -> planOpts name True pinned ins more
      ("--require-pinned" : more) -> planOpts name raw True ins more
      _
        | Just taken <- takeInput args ->
            taken >>= \(f, more) -> planOpts name raw pinned (ins <> [f]) more
      (flag : _) ->
        Left
          ( "no option '"
              <> flag
              <> "' for plan, which takes "
              <> article
              <> " and, at most, --raw, "
              <> "--require-pinned and the input flags\n\n"
              <> usage reg
          )

    costOpts :: Text -> [InputFlag] -> [Text] -> Either Text Command
    costOpts name ins args = case args of
      [] -> Right (Cost name ins)
      _
        | Just taken <- takeInput args ->
            taken >>= \(f, more) -> costOpts name (ins <> [f]) more
      _ -> Left ("cost takes " <> article <> " and its inputs, and nothing else\n\n" <> usage reg)

-- | One input flag at the head of the arguments, if that is what stands there:
-- the flag, and what is left. 'Nothing' when the head is something else, which
-- is what lets all three verbs share the three flags without sharing a parser.
takeInput :: [Text] -> Maybe (Either Text (InputFlag, [Text]))
takeInput args = case args of
  ("--input" : v : rest) -> Just (Right (SoleFile (T.unpack v), rest))
  ("--input-file" : v : rest) ->
    Just ((\(n, f) -> (NamedFile n (T.unpack f), rest)) <$> splitNamed "--input-file" "NAME=FILE" v)
  ("--input-arg" : v : rest) ->
    Just ((\(n, t) -> (NamedArg n t, rest)) <$> splitNamed "--input-arg" "NAME=VALUE" v)
  [flag]
    | flag `elem` ["--input", "--input-file", "--input-arg"] ->
        Just (Left (flag <> " takes a value, and was given none"))
  _ -> Nothing
  where
    -- The first `=`, and no other: a value may contain as many as it likes.
    splitNamed flag shape v = case T.breakOn "=" v of
      (n, r)
        | not (T.null n), Just val <- T.stripPrefix "=" r -> Right (n, val)
      _ -> Left (flag <> " takes " <> shape <> ", not '" <> v <> "'")

-- | What the @run@ options say, before it has been decided whether they say
-- anything coherent.
--
-- One record rather than a fold of positional accumulators, because the flags
-- now belong to three answerers and the refusals below are about which
-- /combinations/ name one answerer: a flag's engine is a fact about the flag,
-- and reading it off an argument position is how a flag comes to be silently
-- accepted by the transport it means nothing to.
data RunOpts = RunOpts
  { roScripted :: !Bool,
    roEngine :: !(Maybe Text),
    roSession :: !(Maybe Text),
    roBinary :: !(Maybe Text),
    roPollMs :: !(Maybe Int),
    roTimeoutMs :: !(Maybe Int),
    roVerbose :: !Bool,
    roAdapter :: !(Maybe Text),
    -- | In the order given, which is the order they reach the child's @argv@.
    roAdapterArgs :: ![Text],
    -- | @--route NAME=BACKEND@, in the order given — which is the order the run
    -- starts them and the order the header prints them, so that an operator can
    -- read the header against their own command line.
    roRoutes :: ![Text],
    roScratch :: !(Maybe Text),
    -- | @--require-pinned@. Belongs to no engine — it is a question about the
    -- program's text, which is the same text whoever answers it — so it is the
    -- one flag 'chooseTarget' neither forbids nor consumes.
    roRequirePinned :: !Bool,
    -- | The input flags, in the order given. They belong to no engine either:
    -- an input is data the /program/ is written from, and every answerer sees
    -- the same program.
    roInputs :: ![InputFlag]
  }

noRunOpts :: RunOpts
noRunOpts = RunOpts False Nothing Nothing Nothing Nothing Nothing False Nothing [] [] Nothing False []

-- | The @run@ options: three mutually exclusive answerers, the knobs that
-- belong to one of them alone, and @--require-pinned@ and the input flags,
-- which belong to none.
parseTarget :: Registry -> [Text] -> Either Text (Target, Bool, [InputFlag])
parseTarget reg args = do
  o <- go noRunOpts args
  t <- chooseTarget reg o
  pure (t, roRequirePinned o, roInputs o)
  where
    go :: RunOpts -> [Text] -> Either Text RunOpts
    go o rest0 = case rest0 of
      [] -> Right o
      ("--scripted" : rest) -> go o {roScripted = True} rest
      ("--verbose" : rest) -> go o {roVerbose = True} rest
      ("--require-pinned" : rest) -> go o {roRequirePinned = True} rest
      _
        | Just taken <- takeInput rest0 ->
            taken >>= \(f, rest) -> go o {roInputs = roInputs o <> [f]} rest
      ("--engine" : v : rest)
        | v `elem` ["acp", "deck"] -> go o {roEngine = Just v} rest
        | otherwise ->
            Left $
              "unknown engine '"
                <> v
                <> "': --engine takes acp (start an adapter and speak the protocol to it) "
                <> "or deck (send to a live agent-deck session)"
      ("--session" : v : rest) -> go o {roSession = Just v} rest
      ("--binary" : v : rest) -> go o {roBinary = Just v} rest
      ("--adapter" : v : rest) -> go o {roAdapter = Just v} rest
      ("--adapter-arg" : v : rest) -> go o {roAdapterArgs = roAdapterArgs o <> [v]} rest
      ("--route" : v : rest) -> go o {roRoutes = roRoutes o <> [v]} rest
      ("--scratch" : v : rest) -> go o {roScratch = Just v} rest
      ("--poll" : v : rest) -> withMs "--poll" v (\n -> go o {roPollMs = Just n} rest)
      ("--timeout" : v : rest) -> withMs "--timeout" v (\n -> go o {roTimeoutMs = Just n} rest)
      (flag : _) -> Left ("no option '" <> flag <> "' for run\n\n" <> usage reg)

    withMs :: Text -> Text -> (Int -> Either Text a) -> Either Text a
    withMs flag v k = case readMaybe (T.unpack v) of
      Just n | n >= 0 -> k n
      _ -> Left (flag <> " takes a number of milliseconds, not '" <> v <> "'")

-- | Which answerer the options name — or a refusal saying which two of them
-- were named at once.
--
-- Every combination refused here is one where a flag would otherwise mean
-- nothing to the transport that was chosen, which is how a run comes to be
-- configured by a line nobody read.
chooseTarget :: Registry -> RunOpts -> Either Text Target
chooseTarget reg o = case (roScripted o, roEngine o, roSession o) of
  (True, Just e, _) -> Left ("--scripted answers from a table and --engine " <> e <> " reaches an agent; pick one")
  (True, _, Just _) -> Left "--scripted and --session name two different answerers; pick one"
  (True, _, _) -> onlyScripted
  (_, Just "acp", Just _) ->
    Left
      "--engine acp starts an adapter of its own, and --session sends to an agent-deck \
      \session somebody else started; pick one"
  -- The default is `stub`, the deterministic double: a command line that named
  -- no adapter must not spawn a real agent, spend a token or touch an account.
  -- (The retired Lean CLI kept the same default, for the same reason.)
  (_, Just "acp", _) -> live (BackendAcp (fromMaybe "stub" (roAdapter o)))
  (_, Just "deck", Nothing) -> Left "--engine deck needs the session to send to: give --session <id> as well"
  (_, _, Just s) -> live (BackendDeck s)
  -- A route refines a default answerer, so a run that named no default has
  -- nowhere to put the questions no route claims — every unpinned ask, every
  -- tool and every person — and saying so is more use than the general refusal
  -- that follows it.
  _
    | not (null (roRoutes o)) ->
        Left
          "--route refines this run's default answerer, and there is none: \
          \give --engine acp or --session <id> as well"
  _ -> Left ("run needs --scripted, --engine acp, or --session <id>\n\n" <> usage reg)
  where
    -- A flag this run's answerer has no use for, refused by name.
    forbid :: Text -> [(Text, Bool)] -> Either Text ()
    forbid engine = \case
      ((flag, True) : _) -> Left (flag <> " is not " <> engine <> "'s to take")
      (_ : rest) -> forbid engine rest
      [] -> Right ()

    acpFlags = [("--adapter", isJust (roAdapter o)), ("--adapter-arg", not (null (roAdapterArgs o))), ("--scratch", isJust (roScratch o))]
    deckFlags = [("--binary", isJust (roBinary o)), ("--poll", isJust (roPollMs o))]
    liveFlags = acpFlags <> deckFlags <> [("--timeout", isJust (roTimeoutMs o)), ("--verbose", roVerbose o)]

    -- `--route` is refused here rather than left inert. Routes *would* be inert
    -- under `--scripted` — `scriptedReply` reads `qPrompt` and nothing else, so
    -- it cannot see the scope routing dispatches on, and a route table could
    -- not change a canned answer even if one were permitted — and a flag that
    -- is silently inert is the defect this whole function exists to prevent.
    onlyScripted
      | not (null (roRoutes o)) =
          Left "--route names live backends and --scripted answers from a table; pick one"
      | otherwise = Scripted <$ forbid "--scripted" liveFlags

    flagsOf :: Scheme -> [(Text, Bool)]
    flagsOf = \case
      SchemeAcp -> acpFlags
      SchemeDeck -> deckFlags

    -- The flags of the schemes this run's route table never reaches.
    --
    -- The generalization of the per-engine refusal to *the set of schemes the
    -- table uses*, default included. At one scheme it is the predicate that
    -- exists today, refusal wording and all: exactly one scheme is foreign, and
    -- the run's own is the only one there is to name, so `--adapter` under a
    -- deck run is still "not the deck engine's to take". At two it refuses
    -- nothing, which is the whole of what a route makes newly meaningful — with
    -- a `deck:` route under an `acp` default, `--binary` and `--poll` are the
    -- run's to take after all.
    forbidForeign :: Set Scheme -> Either Text ()
    forbidForeign used =
      mapM_
        (forbid (T.intercalate " and " (map schemeWord (Set.toAscList used))) . flagsOf)
        [s | s <- [minBound .. maxBound], not (s `Set.member` used)]

    -- One default and the routes that refine it. `--engine acp --adapter X`
    -- and `--session S` *become* the default route with no change in spelling
    -- and no change in meaning: today they name the one backend every question
    -- reaches, and after this they name the backend every question reaches that
    -- no route claims.
    live def = do
      -- A malformed route first, because it is the most local mistake and the
      -- one whose message the operator can act on by retyping one word.
      named <- traverse parseRoute (roRoutes o)
      case firstDuplicate (map fst named) of
        Just m ->
          Left
            ( "--route names the model '"
                <> m
                <> "' twice; a model has one backend in a run"
            )
        Nothing -> Right ()
      let table = routes def named
      forbidForeign (Set.fromList (map schemeOf (routeBackends table)))
      pure . Routed $
        RunRoutes
          { rrRoutes = table,
            rrScratch = T.unpack <$> roScratch o,
            rrAdapterArgs = map T.unpack (roAdapterArgs o),
            rrBinary = T.unpack <$> roBinary o,
            rrPollMs = roPollMs o,
            rrTimeoutMs = roTimeoutMs o,
            rrVerbose = roVerbose o,
            rrAdapterGiven = isJust (roAdapter o)
          }

usage :: Registry -> Text
usage reg =
  T.intercalate
    "\n"
    [ bin <> " — " <> regBanner reg,
      "",
      "  " <> bin <> " list",
      "  " <> bin <> " plan <" <> noun <> "> [--raw] [--require-pinned] [<input>...]",
      "  " <> bin <> " cost <" <> noun <> "> [<input>...]",
      "  " <> bin <> " run  <" <> noun <> "> --scripted [<input>...]",
      runLead <> "--session <id> [--binary PATH] [--poll MS]",
      under (runLead <> "--session <id> ") <> "[--route NAME=BACKEND]...",
      under (runLead <> "--session <id> ") <> "[--timeout MS] [--verbose]",
      runLead <> "--engine acp [--adapter stub|claude|codex|PATH]",
      under (runLead <> "--engine acp ") <> "[--adapter-arg ARG]... [--scratch DIR]",
      under (runLead <> "--engine acp ") <> "[--route NAME=BACKEND]...",
      under (runLead <> "--engine acp ") <> "[--timeout MS] [--verbose]",
      "",
      "  <" <> noun <> "> is " <> T.intercalate " or " (regNames reg),
      "",
      "  <input> is one of the three input flags below. A program that takes",
      "  inputs is a program of them: an input is a define supplied at run time,",
      "  spliced into prompts as data and never asked of anybody. plan and cost",
      "  answer without one — no static fold reads a prompt — and say so on the",
      "  inputs line; run requires every input.",
      "",
      "  --input FILE   the sole input of a program that takes exactly one, read",
      "                 from a file. Takes no NAME=, so a path containing = is",
      "                 never misread",
      "  --input-file NAME=FILE",
      "                 that input, read from a file. Repeatable",
      "  --input-arg NAME=VALUE",
      "                 that input, inline. Repeatable",
      "                 (a file's contents are read as UTF-8 — bytes that are",
      "                 not UTF-8 refuse the run — and one trailing newline is",
      "                 stripped, so a file splices like a define written in",
      "                 the source)",
      "  --scripted     answer from a table of canned replies, and ask nobody",
      "  --engine       acp starts an ACP adapter of its own and speaks the protocol",
      "                 to it over a pipe it owns; deck sends to a live agent-deck",
      "                 session somebody else started (which --session alone selects)",
      "  --session      put every question — model, tool and person alike — to this",
      "                 agent-deck session",
      "  --binary       the agent-deck executable (default: agent-deck, found on PATH)",
      "  --poll         milliseconds between two checks of the session's status",
      "  --adapter      the answering program (default: stub, the deterministic double",
      "                 at ../test/stub_adapter.py); claude and codex are looked for on",
      "                 PATH and then at their machine-local pins; anything else is a",
      "                 path. --engine acp only",
      "  --adapter-arg  one argument for the adapter's argv; repeatable.",
      "                 `--adapter-arg --refuse` is how the stub is told to answer *no*",
      "                 to a person's yes/no question. --engine acp only",
      "  --scratch      run in DIR instead of a fresh temporary directory: where the",
      "                 adapter is started, and the only place an act may write.",
      "                 --engine acp only",
      "  --route        NAME=BACKEND — put the questions this run pins to the model",
      "                 NAME to BACKEND instead of to the default answerer.",
      "                 Repeatable, at most once per NAME. BACKEND is",
      "                 acp:stub|claude|codex|PATH (start an adapter of this run's",
      "                 own) or deck:<id> (send to a live agent-deck session).",
      "                 NAME is a *serving model* — a `served by` pin or one of its",
      "                 spares — and not a party: routing the pin is what makes a",
      "                 fail-over ladder cross providers. A pinned model no --route",
      "                 names, every unpinned ask, and every tool and person take",
      "                 the default. Refuses a NAME this program never pins",
      "  --timeout      milliseconds one turn may take before it is abandoned",
      "  --verbose      narrate the transport on stderr",
      "  --require-pinned",
      "                 refuse the program unless every model ask names the model",
      "                 that serves it (`servedBy`). Checked before anything is",
      "                 printed, started or spent; plan and run, any engine"
    ]
  where
    bin = regBinary reg
    noun = regNoun reg

    -- The `run` lines wrap, and their continuations line up under the first
    -- option rather than at a column somebody counted: the binary's name and
    -- the noun are both the registry's, so a hand-counted indent would be right
    -- for one product and wrong for the other.
    runLead = "  " <> bin <> " run  <" <> noun <> "> "
    under t = T.replicate (T.length t) " "

-- ---------------------------------------------------------------------------
-- Printing
-- ---------------------------------------------------------------------------

say :: Text -> IO ()
say = TIO.putStrLn

-- | Print the message on stderr and stop with this code.
die :: Registry -> Int -> Text -> IO a
die reg code msg = do
  TIO.hPutStrLn stderr (regBinary reg <> ": " <> msg)
  exitWith (ExitFailure code)

-- | A 'Value' over several lines, keys sorted, scalars rendered by
-- "Agentic.Observe" so that every escape in this executable is that module's.
prettyJson :: Int -> Value -> Text
prettyJson ind = \case
  Object o
    | KM.null o -> "{}"
    | otherwise ->
        wrap "{" "}" $
          [ pad (ind + 2) <> renderString (K.toText k) <> ": " <> prettyJson (ind + 2) v
          | (k, v) <- sortOn fst (KM.toList o)
          ]
  Array a
    | V.null a -> "[]"
    | otherwise ->
        wrap "[" "]" $
          [pad (ind + 2) <> prettyJson (ind + 2) v | v <- V.toList a]
  v -> render v
  where
    wrap open close items =
      open <> "\n" <> T.intercalate ",\n" items <> "\n" <> pad ind <> close
    pad n = T.replicate n " "

indentBy :: Int -> Text -> Text
indentBy n = T.intercalate "\n" . map (T.replicate n " " <>) . T.splitOn "\n"

tshow :: (Show a) => a -> Text
tshow = T.pack . show
