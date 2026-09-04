-- |
-- Module      : Agentic.Cli
-- Description : The runner, as a function of the registry it serves.
--
-- Four verbs over a table of named programs: 'list' them, 'plan' one, price it,
-- or run it — and a fifth that answers for one of them and spends nothing.
--
-- > <binary> list  [--json]
-- > <binary> help  NAME
-- > <binary> NAME  --help
-- > <binary> --help
-- > <binary> plan  NAME [--raw] [--require-pinned] [--json]
-- > <binary> cost  NAME
-- > <binary> run   NAME --scripted
-- > <binary> run   NAME --session <id> [--binary PATH] [--poll MS]
-- >                                    [--route NAME=BACKEND]...
-- >                                    [--timeout MS] [--verbose]
-- > <binary> run   NAME --engine acp [--adapter stub|claude|codex|droid|PATH]
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
-- __Four inputs are the runner\'s and not the operator\'s__
-- ('Agentic.Runtime.Facts.runFacts'): @run.backends@, @run.engine@, @run.routes@ and
-- @run.sentinel@ are facts about the run being made, and @run@ binds all four
-- from the command line it was given and from the clock. A flag naming one is
-- refused ('resolveInputs'), because there is nothing for the operator to fix
-- and the fact will be there; @plan@ and @cost@ leave them unbound, because
-- they are making no run. They are inputs like any other in every other
-- respect — a define, spliced as literal chunks, invisible to every fold — and
-- 'runFactsWith' is where they come from.
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
-- == @help@, the verb that spends nothing
--
-- The owner's ruling of 2026-08-22: __for every registered program there is a
-- page saying which arguments and patterns are useful for actually using it__,
-- and @\<binary\> NAME --help@ shows it. So 'rowHelp' is a field of the row and
-- not a 'Maybe': a registry literal that omits it fails to compile, by arity,
-- at every construction site — which is the only place the omission can be
-- caught before an operator meets it, since a registry is a value and this CLI
-- a function of that value.
--
-- Three spellings reach one renderer, and they are byte-identical because there
-- is one of it: @help NAME@ (verb-first, like every other verb here) and
-- @NAME --help@ (the ruling's own, and the one a hand types). @--help@ alone is
-- the usage message on __stdout__ at exit @0@, where bare @\<binary\>@ stays
-- what it was — the usage on stderr at exit @1@. The asymmetry is the point: a
-- command line that asked for nothing is not a request that was answered.
--
-- @NAME@ alone — a registered name with no verb — is __refused__, naming the
-- verbs. It is ambiguous between /tell me about it/ and /do it/, and guessing
-- is the one thing a runner whose next line could start spending must not do.
--
-- __A verb in head position always wins.__ Every new arm is placed after the
-- verbs, so a row named @plan@ or @help@ is unreachable /by name/ rather than
-- ambiguous — which is a thing a gate should shout about, and both gates do,
-- against @list@'s own output rather than against a transcription of it.
-- @'parseCommand'@ is exported for the probe that holds the policy over a
-- synthetic colliding registry, as against the fact about today's two tables.
--
-- __What the page is.__ The row's line, then the numbers 'listFacts' computes —
-- @level@, @cost@, @inputs@, @runFacts@, @pins@, every label printed and an
-- empty list as @—@ — then 'rowHelp' verbatim, then one footer this module
-- owns. __A help text carries no price__: the number here and the number
-- @list --json@ publishes are one 'Facts', so they cannot come to disagree, and
-- an author who would have hand-copied one writes a caveat pointing at @cost@
-- instead. @help@ takes the name and nothing else — it builds the program at
-- every input empty, asks nobody, starts no adapter, and exits @0@.
--
-- __It joins no @--json@__, and there is no @help --json@. @list --json@ is a
-- /chooser's/ table and would make every reader parse the whole toolbox's prose
-- to pick one row; @plan --json@ is per-program detail, and a @help@ key there
-- would be a second spelling of bytes that already have a door. Prose is not a
-- contract in this module (see the refusals below), and a text has no structure
-- to lose: __the machine-readable form of a help text is the help text__. What
-- @help@ promises a program is what every verb here promises — exit @0@, the
-- whole page on stdout, the refusal on stderr under exit @1@.
--
-- == The machine-readable rendering
--
-- @list@ and @plan@ take @--json@ and print, instead of their prose, the object
-- below — one per row for @list@ (in a JSON array, in listing order), one for
-- @plan@. It exists for a program that drives this CLI: the owner's Emacs
-- interface picks a workflow out of @wf list --json@ and prompts for the inputs
-- it names, and __the prose is not a contract__ — a reworded blurb or a widened
-- column must not break a reader.
--
-- __The key names below are an interface. Renaming one is a breaking change__,
-- as is dropping one or changing what it holds; adding a key is not. The order
-- they are emitted in is the encoder's and is promised to nobody, a JSON object
-- being unordered; the order /within/ @inputs@ is declaration order and is
-- promised. Both renderings are computed from one 'Facts', so there is no
-- arrangement in which the number this prints and the number the prose prints
-- disagree.
--
-- > {"name":"wiggum"
-- > ,"blurb":"…"                one line, the row's own
-- > ,"level":"batch"|"pipeline"|"branch"|"loop"     'Agentic.Plan.levelName'
-- > ,"size":31                  'Agentic.Plan.size'
-- > ,"askNodes":9               'Agentic.Plan.askNodes', the asks *written*
-- > ,"minFold":9                least request occurrences on any path, null if none
-- > ,"maxFold":9                greatest, null if no path
-- > ,"paths":1                  how many paths the cost fold has
-- > ,"inputs":[{"name":"plan","source":"command-tail"}] -- operator inputs, ordered
-- > ,"runFacts":["run.engine"]  the run facts this program declares
-- > ,"pins":["partner","worker"]            the models --route may name, sorted
-- > ,"codes":["text","verdict"] plan only; null when the program branches
-- > ,"fold":[{"consults":9,"paths":1}]      plan only; the histogram cost prints
-- > ,"program":{…}              plan --json --raw only; 'Agentic.Observe.printedValue'
-- > }
--
-- @inputs@ carries exactly the names the @has no input named@ refusal names
-- ('operatorInputs'), in declaration order, plus acquisition source metadata.
-- A caller therefore offers the fields @run@ accepts and can pre-bind only the
-- command-tail/stdin fields their descriptors declare. Runner facts remain under
-- @runFacts@, where nothing can mistake them for operator input.
--
-- @pins@ is the other half of what a caller needs to /configure/ a run rather
-- than only to start one: @inputs@ says what to prompt for, and @pins@ says
-- which @--route@ names this program will accept — the one fact a front end
-- needs in order to offer a backend per pin. It is 'pinnedModels', which is the
-- same set 'routeRefusal' checks a @--route@ against, so a caller that offers a
-- field per element offers exactly the routes @run@ will accept: the promise
-- @inputs@ makes, made about routing.
--
-- @codes@ and @fold@ are @plan@'s because they are per-program detail a listing
-- does not need; @cost@ takes no @--json@ because @plan --json@ already carries
-- both of the numbers it prints. @run@ takes none either: its record is the
-- trace it prints as it happens.
--
-- __A refusal is not JSON.__ Every one of them goes to stderr in the words
-- below, under the exit codes below, @--json@ or no @--json@ — so a caller
-- reads the exit code first and parses stdout only at @0@, and gets the same
-- sentence an operator would have got. A second, machine-readable spelling of
-- every refusal in this module is a second thing to keep true, and the exit
-- code already carries the only distinction a caller can act on.
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
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Agentic.Cli
  ( -- * What a CLI is a CLI /of/
    Registry (..),
    Row (..),

    -- * The runner
    cliMain,

    -- * One fact, for the gate that holds it against its reader
    routesFact,

    -- * The parse, for the gate that holds the dispatch's own policy
    --
    -- | A verb in head position beats a row of the same name, and that is
    -- decided here rather than by either registry happening not to collide.
    -- The probe reads it over a /synthetic/ registry every one of whose rows is
    -- named after a verb — @run@, @plan@, @cost@, @list@, @help@ — plus one that
    -- is not, which is the only way to state the policy as against the fact
    -- about today's two tables; 'Command' is exported with it because a parse
    -- nobody can look at is a parse nobody can hold.
    Command (..),
    parseCommand,
  )
where

import Control.Exception
  ( Handler (..),
    IOException,
    SomeAsyncException,
    SomeException,
    catches,
    displayException,
    fromException,
    throwIO,
    try,
  )
import Control.Monad (foldM, unless, void, when)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, withObject, (.:), (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Pair, parseEither)
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum)
import qualified Data.ByteString.Lazy as BL
import Data.List (find, nub, sort, sortOn, tails)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Word (Word64)
import Data.Text.Encoding (decodeUtf8', decodeUtf8Lenient, encodeUtf8)
-- `text`'s own internal module, for one thing and only in a message: the
-- length of a byte string's longest valid UTF-8 prefix, which is the offset an
-- operator needs to find the byte. `UnicodeException` names the offending
-- *byte* and not where it is, and the accept/reject decision below is
-- `decodeUtf8'`'s alone — this only sharpens the refusal.
import Data.Text.Internal.Encoding (validateUtf8Chunk)
import qualified Data.Text.IO as TIO
import Data.Time.Clock (getCurrentTime)
import qualified Data.Vector as V
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (showFFloat)
import qualified Paths_agentic as Paths
import Data.Version (showVersion)
import System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory, getTemporaryDirectory)
import System.Environment (getArgs, getEnvironment, lookupEnv)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.FilePath ((</>))
import System.IO
  ( BufferMode (LineBuffering),
    Handle,
    hClose,
    hIsTerminalDevice,
    hSetBuffering,
    hSetEncoding,
    stderr,
    stdin,
    stdout,
    utf8,
  )
import System.IO.Error (ioeGetErrorString, isUserError)
import System.Posix.IO
  ( OpenFileFlags (creat, exclusive),
    OpenMode (WriteOnly),
    defaultFileFlags,
    fdToHandle,
    openFd,
  )
import System.Posix.Types (Fd (..))
import Text.Read (readMaybe)

import Agentic.Acp
  ( Acp,
    AcpModelConfig (..),
    AcpConfig (..),
    ChildEnvironment,
    inheritChildEnvironment,
    AcpError,
    AdapterSpec,
    adapterConfig,
    pathAdapter,
    stubAdapter,
    renderAcpError,
    engineOfAcpConfigured,
    preflightAcpModel,
    withAcps,
  )
import Agentic.Acp.Claude (claudeAdapter)
import Agentic.Acp.Codex (codexAdapter)
import Agentic.Acp.Droid (droidAdapter)
import Agentic.AgentDeck
  ( DeckConfig (..),
    DeckModelConfig (..),
    DeckError (..),
    defaultDeckConfig,
    renderDeckError,
    engineOfDeck,
    verifyDeckModels,
  )
import qualified Agentic.Engine as Engine
import Agentic.Builder
  ( ProgramOf,
    SomeProgram (..),
    progPlan,
    progRawOut,
    progResultCode,
  )
import Agentic.Chains (servedChains)
import qualified Data.Map.Strict as Map
import Agentic.Runtime
  ( PersistenceHooks (..),
    WorldIO,
    announcingWorld,
    worldOfEngine,
    concurrentWorld,
    chainsOf,
    noChains,
    nullPersistenceHooks,
    runPlanPersisted,
    scriptedWorld,
    sayEl,
    stderrLog,
  )
import Agentic.Runtime (ControlRuntime, newControlRuntime)
import Agentic.Runtime
  ( DeferredEventSink,
    MachineCancelled (..),
    activateEventSink,
    deferredEventSink,
    eventSinkActive,
    handlesEventSink,
    newDeferredEventSink,
    stdoutEventSink,
    withControlInput,
  )
import Agentic.Runtime
  ( LineageOperation (ForkRun, RestartRun, ResumeRun, RootRun),
    AnswerRecord (..),
    Checkpoint (..),
    EffectPhase (EffectCompleted, EffectStarted),
    EffectRecord (EffectRecord),
    RunManifest (..),
    RunStore,
    appendEffectRecord,
    lookupStoredAnswer,
    readAnswerRecords,
    readCheckpoint,
    readEffectRecords,
    readManifest,
    storeReusableAnswer,
    writeCheckpoint,
    storeEventHandle,
    withRunStoreSeeded,
  )
import Agentic.Runtime
  ( EventSink,
    descriptorVersion,
    FailureClass (..),
    OccurrenceId (..),
    RunId,
    RuntimeEvent (..),
    mkRunId,
    protocolVersion,
    storeVersion,
    nullEventSink,
  )
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Agentic.Route
  ( Backend (BackendAcp, BackendDeck),
    Routes,
    Scheme (SchemeAcp, SchemeDeck),
    backendSpelling,
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
import Agentic.RoutingConfig
  ( LoadedRouting (..),
    Realization (..),
    ResolvedRealization (..),
    ResolvedRouting (..),
    Router (..),
    decodeRoutingConfig,
    emptyRoutingConfig,
    loadRoutingConfig,
    expandRoutingConfigV2,
    freezeRoutingConfigV2,
    resolveRoutingConfig,
    thinkingName,
    routesWithProfiles,
  )
import Agentic.RoutingConfig.V2
  ( Persona (personaProfiles),
    SelectedRoutingV2 (selectedPersona, selectedPersonaName, selectedPersonaSource),
    selectRoutingPersona,
  )
import Agentic.RoutingDiscovery
  ( DiscoveryMode (..),
    discoverRoutingInventories,
    sha256Fingerprint,
  )
import Agentic.RoutingSecrets
  ( resolveEngineContexts,
    resolvedEngineBackend,
    resolvedEngineChildEnvironment,
    resolvedEngineCredentialReady,
  )
import Agentic.RoutingInspect
  ( migrateRoutingConfigV1,
    personaSelectionSourceName,
    renderRoutingInspectionV1,
    renderRoutingInspectionV2,
    resolvedRealizationPolicy,
    routingInspectionV1,
    routingInspectionV2,
  )
import Data.Set (Set)
import qualified Data.Set as Set
import Agentic.Runtime
  ( ShellConfig (shellCwd, shellLog, shellTimeoutMs),
    defaultShellConfig,
    executingWorld,
  )
import Agentic.DSL (codeName, printedValue, render, renderString)
import Agentic.RequirePinned (guardUnpinnedAsk)
import Agentic.Cost (costM, costSummary)
import Agentic.Plan
  ( ExecTrace,
    askNodes,
    intentCounts,
    codes,
    level,
    levelName,
    size,
    toolExecNodes,
  )
import Agentic.Schema (El, SCode (..), SomeCode (..), fromSCode)
import Agentic.Schema.Json (codeFromJson, codeJson)
import Agentic.WF (wft)
import Agentic.Runtime.Facts
  ( reservedInput,
    routeDefaultLabel,
    runFactBackends,
    runFactEngine,
    runFactRefusal,
    runFactRoutes,
    runFactSentinel,
    runFacts,
    sessionPolicy,
  )
import Agentic.Workflow
  ( Example (..),
    InputSource (..),
    InputSpec (..),
    inputSpecs,
    supply,
  )
import Agentic.Planning (answerFromJson, billExecFresh, billMemo)

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

-- | One registered program, and the three things every verb needs from it
-- beside the program itself.
--
-- The row is the unit, so a program cannot be registered without them. In
-- particular the canned table travels __beside the program__ rather than in a
-- @scriptFor@ dispatch inside the runner, which is "Example.Isaac"'s own
-- argument for @isaacScript@ ("the keys /are/ the prompt defines those programs
-- are written from", so a key is a prefix by construction rather than by
-- proofreading) applied to every registry alike.
--
-- __'rowHelp' is 'Text' and not @Maybe Text@__, and it is a field and not a
-- @helpFor :: Text -> Text@ dispatch, for one reason with two halves. A
-- registered program nobody can be told how to use is not a thing this table
-- should be able to hold; and a 'Maybe' would oblige the CLI to have an arm
-- that prints /there is no help for this row/ — a sentence its reader can do
-- nothing about, printed by a binary that could have refused to build instead.
-- Every construction site in both registries is positional, so an omitted field
-- is a @Text -> Row@ where a 'Row' is wanted: a type error, at the site, in
-- every tree that builds. A @Text@-keyed dispatch would have made it a
-- pattern-match failure at run time for the one row somebody added and did not
-- document, which is the failure this field exists to remove.
--
-- The two prose fields sit together — one line, then the page — and the script
-- stays last, where the paragraph above still reads: it is the row's answering
-- table and not its documentation.
data Row = Row
  { -- | the program, or the program of its inputs
    rowExample :: !Example,
    -- | one line, for @list@ and for the usage message
    rowDoc :: !Text,
    -- | the page @help@ prints under the computed header: what this row is
    -- for, what its inputs mean, which transport it wants, one worked command
    -- line, one rehearsal, and its caveats. Never a price — the header above
    -- it is the one 'Facts' every verb reads
    rowHelp :: !Text,
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
data ForkEdit = ForkDrop !OccurrenceId | ForkReplace !OccurrenceId !FilePath
  deriving (Eq, Show)

data Command
  = -- | The usage message, asked for: stdout, exit @0@. Bare @\<binary\>@ is
    -- not this — it is a 'Left' carrying the same text, on stderr under exit
    -- @1@, because a command line that asked for nothing was not answered.
    Usage
  | -- | One row's page: its line, the computed header, its 'rowHelp', the
    -- footer. Reached from @help NAME@ and from @NAME --help@ alike, and
    -- unconditional in the name, so a misspelling gets the list of rows rather
    -- than @no verb@.
    Help !Text
  | -- | Sanitized local routing policy; may explicitly refresh catalogues.
    RoutingInspection !Render !(Maybe Text) !DiscoveryMode
  | -- | Mechanical, non-overwriting version-1 to version-2 conversion.
    MigrateRouting !FilePath !FilePath
  | -- | The registry itself: every name, with its one line.
    List !Render
  | -- | The static folds, the printed program when the first 'Bool', and
    -- @--require-pinned@ in the second.
    Plan !Text !Render !Bool !Bool ![InputFlag]
  | -- | The cost summary and the fold it summarizes.
    Cost !Text ![InputFlag]
  | -- | Execute, against one of the three answering services, under
    -- @--require-pinned@ when the 'Bool'.
    Run !Text !Target !Bool ![InputFlag]
  | -- | Structured execution: caller-supplied run id, then the ordinary run.
    Machine !RunId !Text !Target !Bool ![InputFlag]
  | -- | Validate lineage compatibility without creating a child run.
    LineageCheck !LineageOperation !FilePath ![ForkEdit] !Text !Target !Bool ![InputFlag]
  | -- | New immutable child run derived from a stored parent.
    MachineLineage !LineageOperation !RunId !FilePath ![ForkEdit] !Text !Target !Bool ![InputFlag]
-- | Who the output is for: an operator reading it, or a program parsing it.
--
-- It rides on the two verbs whose whole output is a statement about the
-- registry — and on neither of the other two, for reasons that are about those
-- verbs and not about this flag: @cost@ prints nothing @plan --json@ does not
-- carry, and a run's record is its trace.
--
-- The two renderings share a 'Facts' rather than a code path, which is what
-- makes @--json@ a second /rendering/ and not a second /answer/.
data Render
  = -- | the prose, for a person
    Human
  | -- | the object documented in this module's haddock, for a program
    Json
  deriving (Eq)

-- | One resolved operator-input source.
--
-- The first three constructors come from command-line flags. 'NamedStdin' is
-- synthesized after a declared standard-input source is decoded.
data InputFlag
  = -- | @--input FILE@ — the sole input, read from a file
    SoleFile !FilePath
  | -- | @--input-file NAME=FILE@
    NamedFile !Text !FilePath
  | -- | @--input-arg NAME=VALUE@
    NamedArg !Text !Text
  | -- | A declared standard-input value, decoded once before route stabilization.
    NamedStdin !Text !Text

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
-- 'Agentic.Acp.permissionByIntent' authorizes an effect's tool call in the session's
-- working directory, so a run that had not been given one of its own would be
-- authorizing writes into whatever directory it was started from.
data RunRoutes = RunRoutes
  { -- | The default, and the routes that refine it.
    rrRoutes :: !(Routes Backend),
    -- | Routes exactly as the command line supplied them, before YAML.
    rrCommandRoutes :: !(Routes Backend),
    -- | The layered YAML policy loaded before any program or backend.
    rrRouting :: !LoadedRouting,
    -- | Trust-selected v2 policy, if the loaded files are version 2.
    rrSelectedRoutingV2 :: !(Maybe SelectedRoutingV2),
    -- | Explicit persona name before precedence is applied.
    rrPersonaOverride :: !(Maybe Text),
    -- | Concrete-model overrides keyed by runtime axis.
    rrRealizeOverrides :: !(Map.Map Text Text),
    -- | Cache/network behavior chosen explicitly for this operation.
    rrDiscoveryMode :: !DiscoveryMode,
    -- | Exact environments retained only until their ACP children are spawned.
    rrChildEnvironments :: !(Map.Map Backend ChildEnvironment),
    -- | Whether inventory selection and secret resolution have run once.
    rrV2Frozen :: !Bool,
    -- | Concrete settings by runtime model axis, populated after the program is built.
    rrRealizations :: !(Map.Map Text ResolvedRealization),
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
      ( do
          configured <- loadCommandRouting cmd
          either (die reg 1 . ("routing configuration: " <>)) (execute reg) configured
      )
        `catches` [ Handler $ \(e :: DeckError) -> die reg 2 ("transport: " <> renderDeckError e),
                    Handler $ \(e :: AcpError) -> die reg 2 ("transport: " <> renderAcpError e),
                    Handler $ handleEngineError reg,
                    Handler $ \(e :: IOError) ->
                      die reg 3 $
                        if isUserError e
                          then T.pack (ioeGetErrorString e)
                          else T.pack (show e)
                  ]

handleEngineError :: Registry -> Engine.EngineError -> IO a
handleEngineError reg error' =
  case Engine.engineFailureKind error' of
    Engine.TransportFailure -> die reg 2 ("transport: " <> Engine.engineFailureMessage error')
    Engine.ProtocolFailure -> die reg 3 (Engine.engineFailureMessage error')

-- | Attach optional user/project routing policy only to commands that can reach
-- a live backend. Static and scripted commands remain independent of local
-- machine configuration.
loadCommandRouting :: Command -> IO (Either Text Command)
loadCommandRouting = \case
  Run name target pinned inputs -> withTarget target (\target' -> Run name target' pinned inputs)
  Machine run name target pinned inputs -> withTarget target (\target' -> Machine run name target' pinned inputs)
  LineageCheck op parent edits name target pinned inputs ->
    withTarget target (\target' -> LineageCheck op parent edits name target' pinned inputs)
  MachineLineage op run parent edits name target pinned inputs ->
    withTarget target (\target' -> MachineLineage op run parent edits name target' pinned inputs)
  command -> pure (Right command)
  where
    withTarget Scripted rebuild = pure (Right (rebuild Scripted))
    withTarget (Routed routes') rebuild = do
      loaded <- loadRoutingConfig
      environmentPersona <- fmap T.pack <$> lookupEnv "AGENT_CAT_PERSONA"
      pure $ do
        config <- loaded
        selected <- case loadedRoutingV2User config of
          Nothing -> do
            when
              ( isJust (rrPersonaOverride routes')
                  || not (Map.null (rrRealizeOverrides routes'))
                  || rrDiscoveryMode routes' /= DiscoveryNormal
              )
              (Left "--persona, --realize, --offline, and --refresh-models require version-2 routing")
            Right Nothing
          Just user ->
            Just <$> selectRoutingPersona user (rrPersonaOverride routes') environmentPersona (loadedRoutingV2Project config)
        effective <- routesWithProfiles (loadedRouting config) (rrCommandRoutes routes')
        pure
          ( rebuild
              ( Routed
                  routes'
                    { rrRoutes = effective,
                      rrRouting = config,
                      rrSelectedRoutingV2 = selected
                    }
              )
          )

-- | Which verb, and — for @run@ — the facts the run supplies about itself.
--
-- __Only @run@ binds a run fact__, and that is not an omission. A run fact is a
-- statement about a run that is being made ('Agentic.Runtime.Facts.runFacts'), and
-- @plan@ and @cost@ are making none: there is no backend, no engine and no
-- session to describe, and a number bound there would be a claim about a run
-- nobody asked for. So the two static verbs leave them unbound, exactly as they
-- leave a subject nobody gave unbound, and the @inputs@ line says so — which
-- costs them nothing, because no static fold reads a prompt and a program
-- therefore prices identically bound or not.
-- __The two static-est verbs come first and neither builds anything__:
-- 'Usage' prints a text that is a function of the registry's four fields, and
-- 'Help' builds one program at every input empty, which is what @list@ already
-- does for every row.
execute :: Registry -> Command -> IO ()
execute reg = \case
  Usage -> say (usage reg) >> exitSuccess
  Help name -> helpCmd reg name >> exitSuccess
  RoutingInspection rendering persona mode -> routingInspectionCmd reg rendering persona mode >> exitSuccess
  MigrateRouting source outputPath -> migrateRoutingCmd reg source outputPath >> exitSuccess
  List r -> listCmd reg r >> exitSuccess
  Plan name r raw pinned ins -> withExample reg pinned False noRefusal name [] ins (planCmd r raw)
  Cost name ins -> withExample reg False False noRefusal name [] ins (\f _ -> costCmd f)
  Run name target pinned ins ->
    withRunExample reg pinned name target ins $ \effective _ program bindings ->
      withFinalTarget reg effective program (\finalTarget -> runCmd reg name finalTarget program bindings)
  Machine runId name target pinned ins ->
    withMachineControls runId name target $ \control ->
      withRunExample reg pinned name target ins $ \effective _ program bindings ->
        withFinalTarget reg effective program (\finalTarget -> runMachineCmd control reg runId name finalTarget program bindings)
  LineageCheck lineage parent edits name target pinned ins ->
    withRunExample reg pinned name target ins $ \effective _ program _ ->
      withFinalTarget reg effective program (\finalTarget -> void (validateLineage lineage parent edits name finalTarget program))
  MachineLineage lineage runId parent edits name target pinned ins ->
    withMachineControls runId name target $ \control ->
      withRunExample reg pinned name target ins $ \effective _ program bindings ->
        withFinalTarget reg effective program (\finalTarget -> runMachineLineageCmd control reg lineage runId parent edits name finalTarget program bindings)

routingInspectionCmd :: Registry -> Render -> Maybe Text -> DiscoveryMode -> IO ()
routingInspectionCmd reg rendering persona mode = do
  loadedResult <- loadRoutingConfig
  loaded <- either (die reg 1 . ("routing configuration: " <>)) pure loadedResult
  case loadedRoutingV2User loaded of
    Nothing -> do
      when (isJust persona || mode /= DiscoveryNormal) $
        die reg 1 "--persona, --offline, and --refresh-models require version-2 routing"
      case rendering of
        Human -> say (renderRoutingInspectionV1 loaded)
        Json -> sayJson (routingInspectionV1 loaded)
    Just user -> do
      environmentPersona <- fmap T.pack <$> lookupEnv "AGENT_CAT_PERSONA"
      selected <-
        either (die reg 1 . ("routing configuration: " <>)) pure $
          selectRoutingPersona user persona environmentPersona (loadedRoutingV2Project loaded)
      let authored = Map.fromList [(name, []) | name <- Map.keys (personaProfiles (selectedPersona selected))]
          commandRoutes = routes (BackendAcp "routing-inspection") []
      expanded <-
        either (die reg 1 . ("routing configuration: " <>)) pure $
          expandRoutingConfigV2 selected Map.empty commandRoutes authored
      ambient <- Map.fromList <$> getEnvironment
      let required = nub (map (routerName . resolvedRouter) (Map.elems (resolvedRealizations expanded)))
      contexts <-
        either (die reg 1 . ("routing configuration: " <>)) pure $
          resolveEngineContexts selected required ambient
      cacheHome <- routingCacheHome
      now <- getCurrentTime
      inventories <-
        discoverRoutingInventories mode cacheHome now selected contexts required
          >>= either (die reg 1 . ("routing configuration: " <>)) pure
      resolved <-
        either (die reg 1 . ("routing configuration: " <>)) pure $
          freezeRoutingConfigV2 selected inventories expanded
      let readiness = Map.map resolvedEngineCredentialReady contexts
      case rendering of
        Human -> say (renderRoutingInspectionV2 loaded selected resolved)
        Json -> sayJson (routingInspectionV2 loaded selected readiness inventories resolved)

migrateRoutingCmd :: Registry -> FilePath -> FilePath -> IO ()
migrateRoutingCmd reg source outputPath = do
  when (source == outputPath) $ die reg 1 "--migrate-routing refuses to overwrite its source"
  outputExists <- doesFileExist outputPath
  when outputExists $ die reg 1 ("--migrate-routing refuses to overwrite existing " <> T.pack outputPath)
  bytes <- BS.readFile source
  config <- either (die reg 1 . ("routing migration: " <>)) pure (decodeRoutingConfig bytes)
  output <- either (die reg 1 . ("routing migration: " <>)) pure (migrateRoutingConfigV1 config)
  descriptor <- openFd outputPath WriteOnly defaultFileFlags {exclusive = True, creat = Just 0o600}
  handle <- fdToHandle descriptor
  BS.hPut handle output
  hClose handle
  say ("wrote version-2 routing to " <> T.pack outputPath)

withFinalTarget :: Registry -> Target -> ProgramOf r -> (Target -> IO a) -> IO a
withFinalTarget reg target program action = do
  finalized <- finalizeTargetForProgram target program
  either (die reg 1 . ("routing configuration: " <>)) action finalized

data MachineControl = MachineControl ControlRuntime DeferredEventSink EventSink

-- | Start controls before stdin or route-dependent program construction.
withMachineControls :: RunId -> Text -> Target -> (Maybe MachineControl -> IO ()) -> IO ()
withMachineControls runId name initialTarget action = do
  handle <- machineControlHandle
  case handle of
    Nothing -> action Nothing
    Just controlHandle -> do
      runtime <- newControlRuntime
      deferred <- newDeferredEventSink
      let sink = deferredEventSink deferred
      outcome <- try (withControlInput controlHandle sink runtime (action (Just (MachineControl runtime deferred sink))))
      case outcome of
        Right () -> pure ()
        Left (err :: SomeException)
          | Just (MachineCancelled why) <- fromException err -> do
              active <- eventSinkActive deferred
              unless active $ do
                actual <- stdoutEventSink runId
                void (activateEventSink deferred actual (RunStarted name (targetLabel initialTarget)))
              sink (RunCancelled (T.pack why))
              throwIO (ExitFailure 130)
          | otherwise -> throwIO err

-- | The verb owes the program no precondition of its own — @plan@ and @cost@,
-- which read no flag that is a claim about the program's text.
noRefusal :: ProgramOf r -> Maybe Text
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
routeRefusal :: Registry -> Target -> ProgramOf r -> Maybe Text
routeRefusal _ Scripted _ = Nothing
routeRefusal reg (Routed rr) prog = case servedChains (progRawOut prog) of
  Left _ -> Nothing
  Right _ ->
    let pinnable = pinnedModels prog
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
          | (m, _) <- routeNamed (rrCommandRoutes rr),
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
--
-- The fifth argument is the runner's own bindings — the run facts, empty on the
-- two static verbs (see 'execute') — and it is threaded here rather than read
-- inside 'runCmd' because an input is bound when the /program is built/, which
-- is before the verb has a program to run.
--
-- The continuation is handed the row's 'Facts' as well as the program, because
-- every static verb says some of them and only this function has the row and
-- the program at once. 'Facts' is lazy throughout, so @run@ — which passes
-- 'const' and says none of them — prices nothing to say nothing.
withExample ::
  Registry ->
  Bool ->
  Bool ->
  (forall r. ProgramOf r -> Maybe Text) ->
  Text ->
  [(Text, Text)] ->
  [InputFlag] ->
  (forall r. Facts -> ProgramOf r -> [Given] -> IO ()) ->
  IO ()
withExample reg pinned needsAll refuses name facts ins k = case regLookup reg name of
  Nothing -> die reg 1 (noSuchRow reg name)
  Just row -> do
    resolved <- resolveInputs name needsAll facts (rowExample row) ins
    case resolved of
      Left why -> die reg 1 why
      Right (SomeProgram prog, bs)
        | pinned, Just why <- guardUnpinnedAsk (progRawOut prog) -> die reg 1 ("refused: " <> why)
        | Just why <- refuses prog -> die reg 1 why
        | otherwise -> k (factsOf name row prog) prog bs >> exitSuccess

-- | Build a live program and its routing-dependent run facts to a fixed point.
-- A program may branch while its Haskell value is built, so deriving routes
-- once before that build can make @run.routes@ disagree with execution. The
-- sentinel is held fixed throughout; only the target-derived facts move.
withRunExample ::
  Registry ->
  Bool ->
  Text ->
  Target ->
  [InputFlag] ->
  (forall r. Target -> Facts -> ProgramOf r -> [Given] -> IO ()) ->
  IO ()
withRunExample reg pinned name initialTarget inputs k = case regLookup reg name of
  Nothing -> die reg 1 (noSuchRow reg name)
  Just row -> do
    prepared <- prepareRunInputs name (rowExample row) inputs
    case prepared of
      Left why -> die reg 1 why
      Right inputs' -> do
        sentinel <- freshSentinel
        settle row sentinel inputs' [] 0 initialTarget
  where
    settle row sentinel inputs' seen turns target
      | turns >= (16 :: Int) = die reg 1 "routing configuration and run facts did not converge after 16 program builds"
      | otherwise = do
          let runFacts' = runFactsWith reg name target sentinel
          resolved <- resolveInputs name True runFacts' (rowExample row) inputs'
          case resolved of
            Left why -> die reg 1 why
            Right (SomeProgram prog, bindings) -> case resolveTargetForProgram target prog of
              Left why -> die reg 1 why
              Right effective
                | targetPolicy effective == targetPolicy target ->
                    if pinned
                      then case guardUnpinnedAsk (progRawOut prog) of
                        Just why -> die reg 1 ("refused: " <> why)
                        Nothing -> finish row effective prog bindings
                      else finish row effective prog bindings
                | targetPolicy effective `elem` seen ->
                    die reg 1 "routing configuration and run facts form a cycle; the program changes which profiles it pins when run.routes changes"
                | otherwise -> settle row sentinel inputs' (targetPolicy target : seen) (turns + 1) effective
    finish :: forall r. Row -> Target -> ProgramOf r -> [Given] -> IO ()
    finish row effective prog bindings = case routeRefusal reg effective prog of
      Just why -> die reg 1 why
      Nothing -> k effective (factsOf name row prog) prog bindings >> exitSuccess

-- | The refusal a name no row answers to earns, from whichever verb was asking.
--
-- __A function because there are now two askers__, and the bytes are load
-- bearing: @ci\/examples.sh@ recovers the whole registry from this sentence
-- (@sed -e 's\/^.*there is \/\/'@) rather than transcribing it, so a new
-- program cannot be registered without being priced, and @agent-workflows@'
-- gate greps @no workflow named@ as its evidence that two registries share one
-- CLI. The wording did not move when @help@ arrived — only the place it is
-- assembled, which is exactly what a second caller is allowed to cost.
noSuchRow :: Registry -> Text -> Text
noSuchRow reg name =
  "no "
    <> regNoun reg
    <> " named '"
    <> name
    <> "'; there is "
    <> T.intercalate " and " (regNames reg)

-- | The refusal a __registered__ name with no verb earns.
--
-- Not @print the help@ and not @run it@: a bare name is ambiguous between /tell
-- me about it/ and /do it/, and a runner whose next line could start spending
-- must not guess which. So it costs the operator one command line and teaches
-- the four things there are to do with a row. Exit @1@ is the usage code —
-- nothing ran, and the way out is another command line.
bareRow :: Registry -> Text -> Text
bareRow reg name =
  "'"
    <> name
    <> "' is "
    <> article reg
    <> " and not a verb; try "
    <> T.intercalate ", " [bin <> " " <> v <> " " <> name | v <- ["help", "plan", "cost"]]
    <> ", or "
    <> bin
    <> " run "
    <> name
    <> " --scripted"
  where
    bin = regBinary reg

-- | @a workflow@ | @an example@ — the registry's noun with the article its
-- first letter asks for.
--
-- One function because three refusals say it and a fourth would have made it
-- four spellings of one agreement about which table was searched.
article :: Registry -> Text
article reg
  | T.any (`elem` ("aeiou" :: String)) (T.take 1 (regNoun reg)) = "an " <> regNoun reg
  | otherwise = "a " <> regNoun reg

-- ---------------------------------------------------------------------------
-- The inputs
-- ---------------------------------------------------------------------------

-- | Every input declaration in source order — the runner's facts among them.
declaredInputSpecs :: Example -> [InputSpec]
declaredInputSpecs = \case
  Fixed _ -> []
  Needs par -> inputSpecs par

-- | Every declared name in the order 'supply' expects.
declaredInputs :: Example -> [Text]
declaredInputs = map inputName . declaredInputSpecs

-- | The operator-facing input declarations; run facts are runner-owned.
operatorInputSpecs :: Example -> [InputSpec]
operatorInputSpecs = filter (not . reservedInput . inputName) . declaredInputSpecs

-- | Names accepted by the existing explicit input flags.
operatorInputs :: Example -> [Text]
operatorInputs = map inputName . operatorInputSpecs

-- | The run facts this program declares, which are the runner's to bind.
runFactInputs :: Example -> [Text]
runFactInputs = map inputName . filter (reservedInput . inputName) . declaredInputSpecs

-- | The program these bindings build — an unbound input being the empty text,
-- which is what a static verb answers about when nobody gave one.
--
-- The one place a 'Given' becomes a 'Program', so @plan@, @cost@ and @list
-- --json@ cannot disagree about which program they are the numbers of.
buildProgram :: Example -> [Given] -> Either Text SomeProgram
buildProgram ex gs = case ex of
  Fixed prog -> Right (SomeProgram prog)
  Needs par -> SomeProgram <$> supply par (map (fromMaybe "" . givenText) gs)

-- | Every declared input, unbound: what a verb that was given nothing binds.
unboundInputs :: Example -> [Given]
unboundInputs ex = [Given n Nothing "" | n <- declaredInputs ex]

-- | Bind a program's inputs from explicit flags, declared standard input, and
-- runner-owned run facts, or say exactly what is wrong with those bindings.
--
-- Every refusal here is a usage error, and each names the one thing to change.
-- The order is the order an operator meets them: a program that takes nothing,
-- a run fact the command line tried to supply, a bare @--input@ where a name is
-- needed, a name the program does not have, a name given twice, a file that
-- will not read, and — at @run@ — an input nobody gave.
--
-- __A run fact is bound here and refused here__, both because this is the one
-- place an input acquires a value. The refusal is
-- 'Agentic.Runtime.Facts.runFactRefusal''s wording, because what it says is a
-- statement about inputs and not about this command line; the binding comes
-- from the third argument, which only @run@ fills. So the operator's own inputs
-- and the runner's arrive at 'Given' by the same door, print on the same
-- @inputs@ line, and differ in exactly one visible respect: where the text came
-- from.
--
-- __Every list an operator is shown names only their own inputs.__ A program
-- that declares @subject@ and @run.engine@ takes /one/ input as far as a
-- command line is concerned, so @--input FILE@ still means @subject@ and the
-- \"it takes …\" refusals still list what there is to give. A count that
-- included the runner's facts would be telling the operator to supply
-- something this function is about to refuse them.
prepareRunInputs :: Text -> Example -> [InputFlag] -> IO (Either Text [InputFlag])
prepareRunInputs name ex ins = case nameInputFlags name ex ins of
  Left why -> pure (Left why)
  Right pairs -> case [spec | spec <- operatorInputSpecs ex, inputSource spec == StandardInput] of
    [] -> pure (Right ins)
    [spec]
      | inputName spec `elem` map fst pairs -> pure (Right ins)
      | otherwise -> do
          legacyControls <- (== Just "1") <$> lookupEnv "AGENT_CAT_CONTROL_STDIN"
          if legacyControls
            then pure (Left "standard-input workflow data conflicts with legacy AGENT_CAT_CONTROL_STDIN controls; use the separate control fd")
            else do
              terminal <- hIsTerminalDevice stdin
              if terminal
                then pure (Left ("run needs input '" <> inputName spec <> "' from standard input; pipe UTF-8 text or supply it with --input-arg/--input-file"))
                else do
                  bytes <- BS.hGetContents stdin
                  pure $ do
                    value <- decodeInputBytes "standard input" bytes
                    pure (ins <> [NamedStdin (inputName spec) value])
    _ -> pure (Left "workflow declares more than one standard-input source")

nameInputFlags :: Text -> Example -> [InputFlag] -> Either Text [(Text, InputFlag)]
nameInputFlags name ex ins = do
  pairs <- traverse named ins
  case firstDuplicate (map fst pairs) of
    Just n -> Left ("input '" <> n <> "' was given twice")
    Nothing -> Right pairs
  where
    names = operatorInputs ex

    named f = case f of
      SoleFile _ -> case names of
        [n] -> Right (n, f)
        _ ->
          Left
            ( name
                <> " takes "
                <> tshow (length names)
                <> (if length names == 1 then " input (" else " inputs (")
                <> T.intercalate ", " names
                <> "); name them with --input-arg or --input-file"
            )
      NamedFile n _ -> known n f
      NamedArg n _ -> known n f
      NamedStdin n _ -> known n f

    known n f
      | Just why <- runFactRefusal n = Left why
      | n `elem` names = Right (n, f)
      | otherwise =
          Left
            ( name
                <> " has no input named '"
                <> n
                <> "'; it takes "
                <> T.intercalate ", " names
            )

resolveInputs ::
  Text ->
  Bool ->
  [(Text, Text)] ->
  Example ->
  [InputFlag] ->
  IO (Either Text (SomeProgram, [Given]))
resolveInputs name needsAll facts ex ins = case ex of
  Fixed prog
    | null ins -> pure (Right (SomeProgram prog, []))
    | otherwise -> pure (Left (name <> " takes no input"))
  Needs _ -> case nameInputFlags name ex ins of
    Left why -> pure (Left why)
    Right pairs -> do
      read' <- traverse (\(n, src) -> fmap ((,) n) <$> inputText n src) pairs
      pure $ do
        given <- sequence read'
        bounds <- traverse (bind given) (declaredInputs ex)
        prog <- buildProgram ex bounds
        pure (prog, bounds)
  where
    inputText n = \case
      NamedArg _ value -> pure (Right (value, sizeOf value <> " given with --input-arg"))
      NamedStdin _ value -> pure (Right (value, sizeOf value <> " from standard input"))
      SoleFile path -> fromFile n path
      NamedFile _ path -> fromFile n path

    fromFile n path = do
      got <- try (BS.readFile path)
      pure $ case got :: Either IOException BS.ByteString of
        Left e -> Left ("could not read " <> T.pack path <> ": " <> T.pack (ioeGetErrorString e))
        Right bytes -> do
          value <- decodeInputBytes (T.pack path) bytes
          let normalized = case inputSource (inputSpecFor ex n) of
                PromptInput -> fromMaybe value (T.stripSuffix "\n" value)
                CommandTailInput -> value
                StandardInput -> value
          Right (normalized, sizeOf normalized <> " from " <> T.pack path)

    bind given n = case lookup n facts of
      Just value -> Right (Given n (Just value) (sizeOf value <> " supplied by the runner"))
      Nothing -> case lookup n given of
        Just (value, whence) -> Right (Given n (Just value) whence)
        Nothing
          | needsAll, reservedInput n -> Left (runFactUnbound n)
          | needsAll -> Left ("run needs every input: '" <> n <> "' was not given")
          | otherwise -> Right (Given n Nothing "")

    runFactUnbound n =
      "'"
        <> n
        <> [wft|' is a run fact and this runner bound none; the facts a run supplies are |]
        <> T.intercalate ", " runFacts

inputSpecFor :: Example -> Text -> InputSpec
inputSpecFor ex name = fromMaybe (InputSpec name PromptInput) (find ((== name) . inputName) (declaredInputSpecs ex))

decodeInputBytes :: Text -> BS.ByteString -> Either Text Text
decodeInputBytes source bytes = case decodeUtf8' bytes of
  Left err ->
    Left
      ( source
          <> " is not UTF-8, at byte "
          <> tshow (fst (validateUtf8Chunk bytes))
          <> " of "
          <> tshow (BS.length bytes)
          <> ": "
          <> T.pack (show err)
          <> [wft|; an input is spliced into prompts as text, so bytes that are not UTF-8 refuse the run|]
      )
  Right value -> Right value

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
-- empty, and nothing at all when every one was bound.
--
-- __Two clauses, because there are two reasons an input is empty here.__ One the
-- operator did not give; a run fact nobody could have, because @plan@ is making
-- no run. Both make the printed program a different text from the one a run
-- would put, which is the whole point of the note — but only one of them is
-- something the reader can do anything about.
emptyNote :: [Given] -> [Text]
emptyNote gs = case clauses of
  [] -> []
  cs ->
    [ "  note: " <> T.intercalate "; " cs <> ", so the program below prints",
      "  with them empty — which is a different text from the one a run",
      "  would put.",
      ""
    ]
  where
    unbound p = [givenName g | g <- gs, givenText g == Nothing, p (givenName g)]

    clauses =
      [ c
      | Just c <-
          [ clauseOf (unbound (not . reservedInput)) " was not given" " were not given",
            clauseOf
              (unbound reservedInput)
              " is a run fact, and only run binds it"
              " are run facts, and only run binds them"
          ]
      ]

    -- Both numbers, because one unbound input is the common case and a list
    -- followed by a singular verb reads as a gate nobody proofread.
    clauseOf ns one many = case ns of
      [] -> Nothing
      [n] -> Just (n <> one)
      _ -> Just (T.intercalate ", " ns <> many)

-- | The @inputs@ line: the name, the kind, and where the text came from —
-- never the text, which can be a whole diff.
--
-- An unbound __run fact__ gets its own words. \"Not given\" is what an operator
-- did; a run fact was never theirs to give, and on @plan@ and @cost@ it is
-- unbound because there is no run to describe, which is a different sentence
-- and a different thing to know.
--
-- __What an unbound value says about the folds, exactly.__ Both arms used to
-- close \"the folds below do not depend on it\", and that is true of the common
-- case and not of all of them: an input reaches /prompts/ as literal chunks that
-- no static fold reads, but 'Agentic.Workflow.supply' builds the program
-- __after__ the inputs are known, so an author may branch on one in ordinary
-- Haskell — and then the folds are the folds of the program that value built.
-- @agent-workflows@ does it twice over: @review-deep@ selects a reviewer roster
-- from its @paths@, and @wiggum@ refuses to start a loop whose engine shares one
-- conversation with the work. This function cannot tell the two kinds apart and
-- must not guess, so it states what it does know: which program these numbers
-- are the numbers of.
inputsLine :: Given -> Text
inputsLine b =
  "  inputs    "
    <> givenName b
    <> " (text) "
    <> case givenText b of
      Nothing
        | reservedInput (givenName b) ->
            [wft|— a run fact, and this verb is making no run; the folds below are those of the program an unbound one builds|]
        | otherwise ->
            [wft|— not given; the folds below are those of the program an empty value builds|]
      Just _ -> "= " <> givenWhence b

-- ---------------------------------------------------------------------------
-- What a rendering renders
-- ---------------------------------------------------------------------------

-- | Everything the static verbs say about one registered row, in one value.
--
-- __One truth, two renderings.__ @plan@'s prose, @cost@'s prose and both
-- @--json@ objects read their numbers here and nowhere else, so the arrangement
-- in which the object and the paragraph disagree about a program's price does
-- not exist. It is a record and not a class of separate helpers because that is
-- what makes the sharing checkable: a field a rendering forgets is a field the
-- other still has, and a number derived twice would have to be written twice
-- here to differ.
--
-- __No field is strict, deliberately.__ The human @list@ prints two of them per
-- row, and a strict record would price seventy-one programs to print
-- seventy-one lines; @run@ takes a 'Facts' it never looks at at all
-- ('withExample'). Laziness is what lets the one record serve every verb
-- without any of them paying for the fields it does not say.
data Facts = Facts
  { factName :: Text,
    -- | 'rowDoc' — the row's one line
    factBlurb :: Text,
    -- | The result code of the closed program.
    factResult :: SomeCode,
    factLevel :: Text,
    factSize :: Integer,
    factAskNodes :: Integer,
    factIntents :: (Integer, Integer, Integer),
    factToolExecNodes :: Integer,
    -- | @(minFold, maxFold, paths)@, as 'renderSummary' prints it
    factSummary :: (Maybe Integer, Maybe Integer, Integer),
    -- | 'Nothing' when the program branches, so no one sequence of answer kinds
    factCodes :: Maybe [Text],
    -- | cost fold as @(request occurrences, path multiplicity)@
    factFold :: [(Integer, Int)],
    -- | 'operatorInputSpecs'
    factInputs :: [InputSpec],
    factRunFacts :: [Text],
    -- | Every model this program pins — the @served by@ primaries and their
    -- spares — sorted, and @[]@ on a chain table that is ill-defined, which the
    -- run is about to refuse in its own words ('routeRefusal' passes the same
    -- case over in the same silence).
    factPins :: [Text]
  }

-- | The facts of one row, at the program its inputs built.
--
-- The program is the caller's because it is the caller who knows which one:
-- @plan review-lite --input ./commit.diff@ is answering about the program that
-- diff builds, and 'listFacts' about the one an empty value builds. Both are
-- 'buildProgram''s work, and this reads the folds off whichever it is given.
factsOf :: Text -> Row -> ProgramOf r -> Facts
factsOf n row prog =
  Facts
    { factName = n,
      factBlurb = rowDoc row,
      factResult = fromSCode (progResultCode prog),
      factLevel = levelName (level p),
      factSize = size p,
      factAskNodes = askNodes p,
      factIntents = intentCounts p,
      factToolExecNodes = toolExecNodes p,
      factSummary = costSummary p,
      factCodes = map codeName <$> codes p,
      -- Sorted before it is grouped, because a multiset has no order of its own
      -- to report; @Explain.leafBills@ sorts the same one for the same reason.
      factFold = runLengths (sort (costM p)),
      factInputs = operatorInputSpecs (rowExample row),
      factRunFacts = runFactInputs (rowExample row),
      factPins = pinnedModels prog
    }
  where
    p = progPlan prog

-- | Every model a program pins, as @--route@ may name them: the @served by@
-- primaries and their spares, sorted and deduplicated.
--
-- __One function and not three lists.__ 'routeRefusal' refuses a @--route@
-- naming anything outside it, the run's header prints the members no @--route@
-- claimed, and @--json@ publishes it under @pins@ — so a caller that offers a
-- field per element offers exactly the routes @run@ will accept, which is the
-- promise 'operatorInputs' makes about @inputs@.
--
-- An alternate is a model name and is routed like any other, which is why it is
-- the keys /and/ the values. An ill-defined table is @[]@ rather than a refusal:
-- the run is about to refuse it in its own words with both spellings named, and
-- until then a table that cannot be built cannot say which models are pinned
-- either.
pinnedModels :: ProgramOf r -> [Text]
pinnedModels prog = case servedChains (progRawOut prog) of
  Left _ -> []
  Right t -> sort (nub (Map.keys t <> concat (Map.elems t)))

-- | The facts of a row nobody gave anything: the numbers of the program an
-- empty value builds, which is exactly what @plan@ and @cost@ answer with when
-- no @--input@ was passed.
--
-- __That is a real qualification and not a formality__ ('inputsLine' has the
-- long version): an input reaches prompts as literal chunks no fold reads, but
-- 'Agentic.Workflow.supply' builds the program /after/ the inputs are known, so
-- an author may branch on one — and then a listing's numbers are the numbers of
-- the program the empty value built. The 'Left' is 'supply''s own words and
-- cannot arise from here, one text per declared name being what it asks for.
listFacts :: Text -> Row -> Either Text Facts
listFacts n row = do
  SomeProgram prog <- buildProgram ex (unboundInputs ex)
  pure (factsOf n row prog)
  where
    ex = rowExample row

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

-- | The fields every @--json@ object carries.
--
-- __These key names are an interface.__ The owner's Emacs interface reads them;
-- renaming one, dropping one or changing what it holds is a breaking change,
-- and adding one is not. @minFold@ and @maxFold@ are @null@ exactly when the
-- program has no path — the bound that does not exist is absent rather than
-- zero, which would be a claim about a program that consults nothing.
--
-- The /order/ the keys come out in is the encoder's and is not part of it: a
-- JSON object is unordered, and a reader that depended on the order would be
-- depending on @aeson@'s key map. The one order that is promised is @inputs@',
-- which is declaration order, because that is the order an interface should ask
-- for them in.
runnerVersion :: Text
runnerVersion = T.pack (showVersion Paths.version)

factFields :: Facts -> [Pair]
factFields f =
  [ "descriptorVersion" .= descriptorVersion,
    "runnerVersion" .= runnerVersion,
    "protocolVersions" .= [protocolVersion],
    "storeVersions" .= [storeVersion],
    "capabilities"
      .= object
        [ "structuredRun" .= True,
          "wholeRunCancel" .= True,
          "controlFd" .= (3 :: Int),
          "requestControls" .= True,
          "steering" .= True,
          "interactiveRetry" .= True,
          "schedulerRedirect" .= True,
          "semanticResume" .= True,
          "immutableFork" .= True,
          "restartFromScratch" .= True,
          "protocolNegotiation" .= True,
          "routingInspection" .= True,
          "routingJsonVersion" .= (2 :: Int),
          "personaRouting" .= True,
          "modelAliasRouting" .= True,
          "consults" .= consults,
          "observes" .= observes,
          "effects" .= effects,
          "effectful" .= (effects > 0),
          "toolExecution" .= (factToolExecNodes f > 0)
        ],
    "name" .= factName f,
    "blurb" .= factBlurb f,
    "result" .= codeJson (factResult f),
    "level" .= factLevel f,
    "size" .= factSize f,
    "askNodes" .= factAskNodes f,
    "minFold" .= mn,
    "maxFold" .= mx,
    "paths" .= paths,
    "inputs" .= map inputDescriptor (factInputs f),
    "runFacts" .= factRunFacts f,
    "pins" .= factPins f
  ]
  where
    (mn, mx, paths) = factSummary f
    (consults, observes, effects) = factIntents f

    inputDescriptor spec =
      object
        [ "name" .= inputName spec,
          "source" .= inputSourceWord (inputSource spec)
        ]

    inputSourceWord PromptInput = ("prompt" :: Text)
    inputSourceWord CommandTailInput = "command-tail"
    inputSourceWord StandardInput = "stdin"
-- | The two @plan@ adds: the codes when the program is a straight line, and the
-- per-path fold @cost@ prints as a row of runs.
--
-- A run becomes @{"consults":n,"paths":k}@ rather than a pair, because a
-- two-element array is a shape a reader has to be told how to read and a
-- named field is one they can. They are @plan@'s and not @list@'s for the
-- reason the prose splits the same way: a listing is a table of what there is,
-- and these are detail about one program.
planFields :: Facts -> [Pair]
planFields f =
  factFields f
    <> [ "codes" .= factCodes f,
         "fold" .= [object ["consults" .= n, "paths" .= k] | (n, k) <- factFold f]
       ]

-- ---------------------------------------------------------------------------
-- help
-- ---------------------------------------------------------------------------

-- | One row's page: its line, the numbers, its own text, the footer.
--
-- __Half of it is computed and half of it is authored, and the split is the
-- design.__ The header is 'listFacts' — the very 'Facts' @list@, @list --json@
-- and (at empty inputs) @plan@ read — so the number an operator reads here and
-- the number a gate pins cannot disagree; 'rowHelp' is what no fold can say,
-- and it is printed verbatim, because a renderer that reflowed it would be a
-- second thing to keep true about prose. Every label is printed even when its
-- list is empty, as @—@: that a row pins no model is a fact worth seeing,
-- because it says @--route@ will refuse every name.
--
-- __It takes the name and nothing else — no input flags.__ The numbers are the
-- row at every input empty, which is the price @list@ publishes; a header that
-- moved with a flag would be teaching by a number the reader did not ask for,
-- and @cost NAME [\<input\>...]@ is the verb whose whole job is that question.
-- The footer says so, once, rather than in one text per row.
--
-- A row whose program will not build at empty inputs stops here rather than
-- printing a page with a hole in it, for 'listCmd''s reason: that is
-- 'Agentic.Workflow.supply' failing at a call that gives it one text per
-- declared name, which is a bug and not a workflow's business.
helpCmd :: Registry -> Text -> IO ()
helpCmd reg name = case regLookup reg name of
  Nothing -> die reg 1 (noSuchRow reg name)
  Just row -> case listFacts name row of
    Left why -> die reg 1 why
    Right f -> do
      say $ factName f <> " — " <> factBlurb f
      say ""
      if factResult f == fromSCode SAck
        then pure ()
        else say $ headed "result" (codeName (factResult f))
      say $ headed "level" (factLevel f)
      say $ headed "cost" (renderSummary (factSummary f))
      say $ headed "inputs" (orDash (map inputName (factInputs f)))
      say $ headed "runFacts" (orDash (factRunFacts f))
      say $ headed "pins" (orDash (factPins f))
      say ""
      say (rowHelp row)
      say ""
      say (helpFooter reg)
  where
    -- `plan`'s own column, so that two pages describing one program indent
    -- their numbers alike.
    headed label v = "  " <> T.justifyLeft 8 ' ' label <> "  " <> v

    orDash [] = "—"
    orDash xs = T.intercalate ", " xs

-- | The last paragraph of every page, in this module and never once per row.
--
-- It carries the three facts that are true of __every__ row and that a help
-- text must therefore not restate: where the shared flags are documented, that
-- the numbers above are the empty invocation's, and which verb answers the
-- question a number that moves with an input actually asks.
helpFooter :: Registry -> Text
helpFooter reg =
  indentBy 2 $
    [wft|
      {bin} --help lists the flags every row shares. The numbers above are this row at
      every input empty — the price {bin} list publishes; an input that shapes a roster
      or bounds a loop prices differently, and {bin} cost <{noun}> [<input>...] is the
      verb that answers that. {bin} plan <{noun}> --raw prints the program these numbers
      are the numbers of.
    |]
  where
    bin = regBinary reg
    noun = regNoun reg

-- ---------------------------------------------------------------------------
-- list
-- ---------------------------------------------------------------------------

-- | The registry, as the operator reads it: one row per name, with its line —
-- or, under @--json@, as a program reads it: an array of 'factFields' objects,
-- in listing order.
--
-- It falls out of making the registry a value and is worth having on both
-- binaries: a table nobody can print is a table that goes stale, and the
-- toolbox is a table whose whole point is being browsed. @--json@ is that same
-- argument for a browser that is not a person — the owner's Emacs interface
-- offers a workflow and then a field per element of @inputs@ — and it prints
-- more per row than the prose because a chooser wants the price beside the
-- name, where a person reading a screenful wants the line that says what it is
-- for.
--
-- Each row is priced at the program its inputs' empty values build
-- ('listFacts'), and one that cannot be built stops the listing rather than
-- being skipped: a listing missing a row is a listing nobody can act on, and
-- this is 'Agentic.Workflow.supply' failing at a call that gives it one text
-- per declared name, which is a bug and not a workflow's business.
listCmd :: Registry -> Render -> IO ()
listCmd reg = \case
  Human -> case traverse (uncurry listFacts) rows of
    Left why -> die reg 1 why
    Right fs -> do
      say $ regBinary reg <> " — " <> tshow (length rows) <> " registered:"
      say ""
      mapM_ line (zip rows fs)
  Json -> case traverse (uncurry listFacts) rows of
    Left why -> die reg 1 why
    Right fs -> sayJson (toJSON [object (factFields f) | f <- fs])
  where
    rows = regRows reg
    width = maximum (1 : map (T.length . fst) rows)
    line ((n, row), f) =
      say $ "  " <> T.justifyLeft width ' ' n <> resultSuffix f <> "  " <> rowDoc row

    resultSuffix f
      | factResult f == fromSCode SAck = ""
      | otherwise = " -> " <> codeName (factResult f)

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
--
-- Under @--json@ it is 'planFields', and @--raw@ still means what it means:
-- the same 'Agentic.Observe.printedValue' the prose indents, under @program@.
-- The @inputs@ lines have no @--json@ counterpart naming /where/ each value
-- came from, and want none — a caller that passed the flags knows what it
-- passed, and @inputs@ names the fields there are to pass.
planCmd :: Render -> Bool -> Facts -> ProgramOf r -> [Given] -> IO ()
planCmd rendering raw f prog gs = case rendering of
  Json -> sayJson (object (planFields f <> [("program", printedValue prog) | raw]))
  Human -> do
    say $ factName f <> ", as elaborated:"
    say ""
    mapM_ (say . inputsLine) gs
    if factResult f == fromSCode SAck
      then pure ()
      else say $ "  result    " <> codeName (factResult f)
    say $ "  level     " <> factLevel f
    say $ "  size      " <> tshow (factSize f)
    say $ "  askNodes  " <> tshow (factAskNodes f)
    say $ "  codes     " <> renderCodes
    say $ "  cost      " <> renderSummary (factSummary f)
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
    -- @null@ and @[]@ are different answers: no single sequence of answer kinds
    -- exists (the program branches), against a program that asks nothing.
    renderCodes = case factCodes f of
      Nothing -> "(none — the program branches, so no one sequence of answer kinds)"
      Just [] -> "[] (nothing is asked)"
      Just cs -> T.intercalate ", " cs

-- ---------------------------------------------------------------------------
-- cost
-- ---------------------------------------------------------------------------

-- | The cost summary, and the fold it is a summary of.
--
-- @costSummary@ is @(minFold, maxFold, paths)@ over @costM@'s bag of bills:
-- one element per path, each its number of request occurrences. Bounds constrain
-- fresh runtime bills;
-- whose @billFresh@ falls outside them is a run of a different program — and
-- when they coincide the program has one price rather than a range.
--
-- The bag is sorted before it is grouped ('factsOf'), because a multiset has no
-- order of its own to report; @Explain.leafBills@ sorts the same one for the
-- same reason.
--
-- __It takes no @--json@__, and that is not an omission: @plan --json@ carries
-- both of the things this prints — @minFold@\/@maxFold@\/@paths@ and the same
-- @fold@ — so a second object saying a subset of the first would be a second
-- contract to keep honest for nothing.
costCmd :: Facts -> [Given] -> IO ()
costCmd f gs = do
  say $ factName f <> ", priced:"
  say ""
  mapM_ (say . inputsLine) gs
  say $ "  costSummary   " <> renderSummary (factSummary f)
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
  say $ "    " <> T.intercalate ", " (map renderRun (factFold f))
  where
    (mn, mx, paths) = factSummary f

    renderRun (n, k)
      | k == (1 :: Int) = tshow n
      | otherwise = tshow n <> " (×" <> tshow k <> ")"

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
runCmd :: Registry -> Text -> Target -> ProgramOf r -> [Given] -> IO ()
runCmd reg name target prog gs =
  void (runCmdObserved nullEventSink say reg name target prog gs)

runCmdObserved :: EventSink -> (Text -> IO ()) -> Registry -> Text -> Target -> ProgramOf r -> [Given] -> IO ExecTrace
runCmdObserved = runCmdControlled Nothing nullPersistenceHooks

runCmdControlled :: Maybe ControlRuntime -> PersistenceHooks -> EventSink -> (Text -> IO ()) -> Registry -> Text -> Target -> ProgramOf r -> [Given] -> IO ExecTrace
runCmdControlled runtimeControls persistence observer output reg name target prog gs = case target of
  Scripted -> do
    authored <- requiredChains
    output $
      "running "
        <> name
        <> " against the scripted table ("
        <> tshow (length script)
        <> " canned replies)"
    -- Without this line a green `--scripted` run reads as evidence that the
    -- gate passed, which is the same class of mistake D5 exists to fix.
    output
      ("  " <> [wft|no command was run; every gate in this program was answered from the table|])
    walkWith authored id (scriptedWorld script)
  Routed parsedRoutes -> do
    authored <- requiredChains
    resolved <-
      case rrSelectedRoutingV2 parsedRoutes of
        Just selected | rrV2Frozen parsedRoutes ->
          case expandRoutingConfigV2 selected (rrRealizeOverrides parsedRoutes) (rrCommandRoutes parsedRoutes) authored of
            Left why -> refuse why
            Right structure ->
              pure
                structure
                  { resolvedRoutes = rrRoutes parsedRoutes,
                    resolvedRealizations = rrRealizations parsedRoutes
                  }
        _ ->
          case resolveRoutingConfig (loadedRouting (rrRouting parsedRoutes)) (rrCommandRoutes parsedRoutes) authored of
            Left why -> refuse why
            Right value -> pure value
    let rr =
          parsedRoutes
            { rrRoutes = resolvedRoutes resolved,
              rrRealizations = resolvedRealizations resolved
            }
        rs = rrRoutes rr
        backends = routeBackends rs
    announceRouting rr
    mapM_ (verifyDeckBackend rr) backends
    -- __The run has a directory of its own exactly when it starts an adapter of
    -- its own__, and there is one of them however many backends there are
    -- (§3.4). Every `acp:` route gets it as its `acpCwd` and `executingWorld`
    -- gets it as its `shellCwd`, because a `toolExec` gate that checked a build
    -- in a directory the act did not write to is a gate that always passes. A
    -- run that is all `deck:` starts nothing and keeps the answer it always
    -- had: this process's directory, which the session need not share.
    --
    -- Independent read-only turns may overlap. Each ACP pipe, deck session and
    -- write-effect lane reserves work in plan order before dependencies are ready,
    -- so later ready work cannot overtake an earlier blocked turn on that lane;
    -- distinct read-only backends remain concurrent.
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
    withAcps [(b, acpConfigFor rr dir w) | b@(BackendAcp w) <- backends] $ \live -> do
      preflightAcp rr live
      services <-
        traverse
          ( \b -> do
              service <- worldOf rr dir live b
              pure (b, service)
          )
          backends
      let connected b = case lookup b services of
            Just service -> service
            Nothing ->
              concurrentWorld $ \_ _ ->
                ioError (userError ("no answering service was made for backend " <> show b))
      walkWith (resolvedChains resolved) (executingWorld (shellAt dir)) (routedWorld (fmap connected rs))
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
          shellLog = output . ("  " <>)
        }

    isAcp b = schemeOf b == SchemeAcp

    preflightAcp rr =
      mapM_
        ( \(backend, acp) ->
            mapM_
              (preflightAcpModel acp . acpModelConfigOf)
              [realization | realization <- Map.elems (rrRealizations rr), resolvedBackend realization == backend]
        )

    verifyDeckBackend rr backend = case backend of
      BackendAcp _ -> pure ()
      BackendDeck session -> do
        let realizations =
              [realization | realization <- Map.elems (rrRealizations rr), resolvedBackend realization == backend]
        case find (not . Map.null . realizationOptions . resolvedSpec) realizations of
          Just _ ->
            throwIO
              ( DeckConfiguration
                  session
                  "agent-deck exposes no generic metadata for backend-specific options"
              )
          Nothing ->
            verifyDeckModels
              (deckConfigFor rr session)
              (map deckModelConfigOf realizations)

    -- The answering service of one backend. Every backend the table names is in
    -- `live` if it is an `acp:` one, because `live` is keyed by exactly the
    -- `acp:` members of `routeBackends` and `fmap` asks about nothing else; the
    -- fourth case is therefore unreachable, and it is a raising 'WorldIO'
    -- rather than an `error` so that a bug here would be a named run failure at
    -- the question that hit it and not a bottom in the middle of a fold.
    worldOf :: RunRoutes -> FilePath -> [(Backend, Acp)] -> Backend -> IO WorldIO
    worldOf rr dir live b = case b of
      BackendDeck s -> worldOfEngine <$> engineOfDeck (deckConfigFor rr s)
      BackendAcp w -> case lookup b live of
        Just acp ->
          pure
            ( worldOfEngine
                ( engineOfAcpConfigured
                    (fmap acpModelConfigOf . (`Map.lookup` rrRealizations rr))
                    (acpConfigFor rr dir w)
                    acp
                )
            )
        Nothing ->
          pure
            ( concurrentWorld
                (\_ _ -> ioError (userError ("no connection was made for the backend acp:" <> T.unpack w)))
            )

    modelConfigOf :: ResolvedRealization -> Engine.ModelConfig
    modelConfigOf realization =
      let spec = resolvedSpec realization
       in Engine.ModelConfig
            { Engine.modelName = realizationModel spec,
              Engine.modelThinking = realizationThinking spec,
              Engine.modelMaxOutput = realizationMaxOutput spec
            }

    deckModelConfigOf :: ResolvedRealization -> DeckModelConfig
    deckModelConfigOf realization =
      DeckModelConfig
        { deckCommonModel = modelConfigOf realization,
          deckModelProvider = routerProvider (resolvedRouter realization)
        }

    acpModelConfigOf :: ResolvedRealization -> AcpModelConfig
    acpModelConfigOf realization =
      AcpModelConfig
        { acpCommonModel = modelConfigOf realization,
          acpModelOptions = realizationOptions (resolvedSpec realization)
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
        output $
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
          output "  no --adapter given, so the stub answers — the same default agent-cat's own CLI takes"
        output $
          "  cwd "
            <> T.pack dir
            <> ", "
            <> tshow (acpTurnTimeoutMs cfg)
            <> "ms to a turn, "
            <> acpSessionPolicy cfg
            <> "; every addressee — model, tool and person — is this one adapter"
        output $ "  a `running` tool's command runs in " <> T.pack dir
      [BackendDeck s] -> do
        let cfg = deckConfigFor rr s
        output $ "running " <> name <> " against agent-deck session " <> deckSession cfg
        output $
          "  polling every "
            <> tshow (deckPollMs cfg)
            <> "ms, "
            <> tshow (deckTimeoutMs cfg)
            <> "ms to a turn, "
            <> deckSessionPolicy
            <> "; every addressee — model, tool and person — is this one session"
        -- The deck engine sends into a session somebody else started, so the
        -- directory a command runs in and the directory that session works in
        -- need not agree. Announce it rather than assume it.
        output
          ("  " <> [wft|a `running` tool's command runs in this process's directory, which the deck session — started by somebody else — need not share|])
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
      output $ "running " <> name <> " against " <> tshow (length bs) <> " backends:"
      -- The label is `Agentic.Workflow.routeDefaultLabel` and not a literal, for
      -- `deckSessionPolicy`'s reason: `run.routes` carries this same table to
      -- the prompts, and a header that named the default answerer one way while
      -- the fact named it another would be one run described twice.
      output $ pad routeDefaultLabel <> backendWords rr (routeDefault (rrRoutes rr))
      output $ pad "" <> "— every unpinned ask, every tool and every person"
      mapM_ route (routeNamed (rrRoutes rr))
      unless (null unclaimed) $
        output $ pad (T.intercalate ", " unclaimed) <> "the default (no --route names them)"
      case [w | BackendAcp w <- bs] of
        [] -> pure ()
        (w : _) ->
          let cfg = acpConfigFor rr dir w
           in output $
                "  cwd "
                  <> T.pack dir
                  <> ", "
                  <> tshow (acpTurnTimeoutMs cfg)
                  <> "ms to a turn, "
                  <> acpSessionPolicy cfg
      case [s | BackendDeck s <- bs] of
        [] -> pure ()
        (s : _) ->
          let cfg = deckConfigFor rr s
           in output $
                "  polling every "
                  <> tshow (deckPollMs cfg)
                  <> "ms, "
                  <> tshow (deckTimeoutMs cfg)
                  <> "ms to a turn, "
                  <> deckSessionPolicy
      output $ "  a `running` tool's command runs in " <> T.pack dir
      where
        route (m, b) = do
          output $ pad m <> backendWords rr b
          -- §5.3: the deck arm's directory caveat is per route and not per run,
          -- because with a mixed table it holds of the `deck:` routes and is
          -- false of the `acp:` ones.
          case b of
            BackendDeck _ ->
              output $
                pad ""
                  <> "— its working directory is its own; this run's tools run in "
                  <> T.pack dir
            BackendAcp _ -> pure ()

        -- Every model this program pins — the `served by` primaries and their
        -- spares — that no route claims. `pinnedModels` has the set in hand and
        -- is the same one `routeRefusal` checks against and `--json` publishes;
        -- an ill-defined table is about to be refused by `walkWith` in its own
        -- words, and until then there is nothing honest to print.
        unclaimed =
          [ m
          | m <- pinnedModels prog,
            not (m `Map.member` routeByModel (rrRoutes rr))
          ]

        labels = routeDefaultLabel : map fst (routeNamed (rrRoutes rr)) <> [T.intercalate ", " unclaimed]
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

    announceRouting rr
      | null sources && Map.null (rrRealizations rr) = pure ()
      | otherwise = do
          output "routing configuration:"
          mapM_ (output . ("  loaded " <>) . T.pack) sources
          mapM_ (output . realizationLine) (Map.toAscList (rrRealizations rr))
      where
        sources = loadedRoutingSources (rrRouting rr)

    realizationLine (axis, realization) =
      let spec = resolvedSpec realization
          router = resolvedRouter realization
          optionSetting (key, String value) = key <> "=" <> value
          optionSetting (key, value) = key <> "=" <> render value
          maxOutputSetting = maybe "; max-output unconstrained" (\value -> "; max-output " <> tshow value) (realizationMaxOutput spec)
          optionSettings
            | Map.null (realizationOptions spec) = ""
            | otherwise =
                "; options "
                  <> T.intercalate "," (map optionSetting (Map.toAscList (realizationOptions spec)))
       in "  "
            <> axis
            <> " = "
            <> backendSpelling (resolvedBackend realization)
            <> "; "
            <> routerProvider router
            <> "/"
            <> realizationModel spec
            <> "; thinking " <> thinkingName (realizationThinking spec)
            <> maxOutputSetting
            <> optionSettings

    requiredChains :: IO (Map.Map Text [Text])
    requiredChains = case servedChains (progRawOut prog) of
      Left why -> refuse why
      Right value -> pure value

    refuse :: Text -> IO a
    refuse why = do
      output ("refusing to start: " <> why)
      exitWith (ExitFailure 1)

    walkWith :: Map.Map Text [Text] -> (WorldIO -> WorldIO) -> WorldIO -> IO ExecTrace
    walkWith chainTable exec world = do
      -- The inputs this run's prompts were built from, announced before the
      -- first question: an operator reading a transcript must be able to see
      -- which subject it was about, and the value itself can be a whole diff.
      mapM_ (output . inputsLine) gs
      let chains
            | Map.null chainTable = noChains
            | otherwise = chainsOf stderrLog chainTable
      mapM_ (output . chainLine) [entry | entry <- Map.toList chainTable, not (null (snd entry))]
      output ""
      (result, tr) <-
        runPlanPersisted runtimeControls persistence observer
          chains
          (announcingWorld (output . ("  " <>)) (exec world))
          (progPlan prog)
      output ""
      report (progResultCode prog) result tr
      pure tr

    chainLine (m, spares) =
      "  "
        <> m
        <> " may be answered instead by "
        <> T.intercalate ", " spares
        <> " — a fail-over is narrated on stderr, and the trace records who answered"

    report :: SCode c -> El c -> ExecTrace -> IO ()
    report code result tr = do
      output "  the run is over."
      case code of
        SAck ->
          output "    answer      () — a workflow's value is the unit; what it did is the trace"
        _ -> do
          output $ "    result      " <> codeName (fromSCode code)
          output (indentBy 6 (sayEl code result))
      output $ "    billFresh   " <> tshow (billExecFresh tr) <> " (request occurrences reached)"
      output $ "    billMemo    " <> tshow (billMemo tr)
        <> " (reusable requests once, every effect occurrence)"

runMachineCmd :: Maybe MachineControl -> Registry -> RunId -> Text -> Target -> ProgramOf r -> [Given] -> IO ()
runMachineCmd control = runMachineWith control RootRun Nothing []

runMachineLineageCmd :: Maybe MachineControl -> Registry -> LineageOperation -> RunId -> FilePath -> [ForkEdit] -> Text -> Target -> ProgramOf r -> [Given] -> IO ()
runMachineLineageCmd control reg lineage runId parentDirectory edits name target prog gs = do
  childStore <- lookupEnv "AGENT_CAT_RUN_STORE"
  when (childStore == Nothing) (ioError (userError "lineage operations require AGENT_CAT_RUN_STORE for the new child run"))
  (parentRunId, inheritedAnswers) <- validateLineage lineage parentDirectory edits name target prog
  runMachineWith control lineage (Just parentRunId) inheritedAnswers reg runId name target prog gs

validateLineage :: LineageOperation -> FilePath -> [ForkEdit] -> Text -> Target -> ProgramOf r -> IO (RunId, [AnswerRecord])
validateLineage lineage parentDirectory edits name target prog = do
  effectiveTarget <- either (ioError . userError . T.unpack) pure (resolveTargetForProgram target prog)
  parentManifest <- readManifest parentDirectory
  let program = printedValue prog
      exactLaunch =
        manifestWorkflow parentManifest == name
          && manifestRunnerVersion parentManifest == runnerVersion
          && manifestProgram parentManifest == program
          && manifestTarget parentManifest == targetLabel effectiveTarget
          && lineagePolicy (manifestPolicy parentManifest) == lineagePolicy (targetPolicy effectiveTarget)
      checkpointMatches checkpoint = checkpointProgram checkpoint == manifestProgram parentManifest
      requireCheckpoint =
        readCheckpoint parentDirectory >>= maybe (ioError (userError "parent run has no compatible checkpoint")) pure
      validateOptionalCheckpoint = do
        checkpoint <- readCheckpoint parentDirectory
        mapM_ (\value -> unless (checkpointMatches value) (ioError (userError "parent checkpoint program fingerprint does not match its immutable manifest"))) checkpoint
        pure checkpoint
      validateCounts checkpoint answers effects =
        unless (checkpointAnswers checkpoint == length answers && checkpointEffects checkpoint == length effects)
          (ioError (userError "parent checkpoint counts do not match its answer/effect journals"))
  inheritedAnswers <- case lineage of
    RestartRun -> do
      unless (null edits) (ioError (userError "answer edits are valid only for fork"))
      unless exactLaunch (ioError (userError "restart launch does not match the parent fingerprint/policy"))
      pure []
    ResumeRun -> do
      unless (null edits) (ioError (userError "answer edits are valid only for fork"))
      checkpoint <- requireCheckpoint
      unless (checkpointMatches checkpoint) (ioError (userError "parent checkpoint program fingerprint does not match its immutable manifest"))
      unless exactLaunch (ioError (userError "resume launch does not match the parent fingerprint/policy"))
      effects <- readEffectRecords parentDirectory
      answers <- filter answerReplayable <$> readAnswerRecords parentDirectory
      validateInheritedAnswers answers
      unless (null effects) (ioError (userError "resume refuses a parent with started or completed effects; restart explicitly instead"))
      validateCounts checkpoint answers effects
      pure answers
    ForkRun -> do
      checkpoint <- validateOptionalCheckpoint
      unless (manifestWorkflow parentManifest == name && manifestRunnerVersion parentManifest == runnerVersion)
        (ioError (userError "fork must use the parent workflow and runner version"))
      effects <- readEffectRecords parentDirectory
      answers <- filter answerReplayable <$> readAnswerRecords parentDirectory
      validateInheritedAnswers answers
      unless (null effects) (ioError (userError "fork refuses a parent with started or completed effects; effects are never replayed"))
      mapM_ (\value -> validateCounts value answers effects) checkpoint
      applyForkEdits edits answers
    RootRun -> ioError (userError "root is not a lineage child operation")
  validateInheritedAnswers inheritedAnswers
  pure (manifestRunId parentManifest, inheritedAnswers)

applyForkEdits :: [ForkEdit] -> [AnswerRecord] -> IO [AnswerRecord]
applyForkEdits edits initialAnswers = do
  case firstDuplicate (map editOccurrence edits) of
    Just occurrence -> ioError (userError ("fork answer was edited more than once: " <> show (occurrenceNumber occurrence)))
    Nothing -> pure ()
  foldM apply initialAnswers edits
  where
    editOccurrence (ForkDrop occurrence) = occurrence
    editOccurrence (ForkReplace occurrence _) = occurrence
    apply answers (ForkDrop occurrence)
      | any ((== occurrence) . answerOccurrence) answers = pure (filter ((/= occurrence) . answerOccurrence) answers)
      | otherwise = ioError (userError ("fork drop names no persisted answer: " <> show (occurrenceNumber occurrence)))
    apply answers (ForkReplace occurrence path)
      | not (any ((== occurrence) . answerOccurrence) answers) =
          ioError (userError ("fork replacement names no persisted answer: " <> show (occurrenceNumber occurrence)))
      | otherwise = do
          bytes <- BS.readFile path
          replacement <- case eitherDecodeStrict' bytes of
            Left why -> ioError (userError ("fork replacement is not JSON: " <> why))
            Right value -> pure value
          original <- case find ((== occurrence) . answerOccurrence) answers of
            Nothing -> ioError (userError "fork replacement lost its persisted answer")
            Just answer -> pure answer
          case replacementFits original replacement of
            Left why -> ioError (userError ("fork replacement " <> why))
            Right () -> pure ()
          pure
            [ if answerOccurrence answer == occurrence
                then answer {answerValue = replacement, answerReplayable = True, answerReplaced = True}
                else answer
              | answer <- answers
            ]

replacementFits :: AnswerRecord -> Value -> Either String ()
replacementFits answer replacement = do
  SomeCode code <- parseEither (withObject "persisted question" (\o -> o .: "code" >>= codeFromJson)) (answerQuestion answer)
  case answerFromJson code replacement of
    Nothing -> Left "answer does not conform to its persisted code/schema"
    Just _ -> Right ()

validateInheritedAnswers :: [AnswerRecord] -> IO ()
validateInheritedAnswers answers = do
  case firstDuplicate (map answerOccurrence answers) of
    Just occurrence -> ioError (userError ("parent answer store duplicates occurrence " <> show (occurrenceNumber occurrence)))
    Nothing -> pure ()
  case firstDuplicate (map answerQuestion answers) of
    Just _ -> ioError (userError "parent answer store duplicates a bare question")
    Nothing -> pure ()
  mapM_ validate answers
  where
    validate answer = case replacementFits answer (answerValue answer) of
      Left why -> ioError (userError ("parent answer store is incompatible: " <> why))
      Right () -> pure ()

runMachineWith :: Maybe MachineControl -> LineageOperation -> Maybe RunId -> [AnswerRecord] -> Registry -> RunId -> Text -> Target -> ProgramOf r -> [Given] -> IO ()
runMachineWith control lineage parent inherited reg runId name target prog gs = do
  effectiveTarget <- either (ioError . userError . T.unpack) pure (resolveTargetForProgram target prog)
  store <- lookupEnv "AGENT_CAT_RUN_STORE"
  owner <- fmap T.pack <$> lookupEnv "AGENT_CAT_RUN_OWNER"
  case store of
    Nothing -> stdoutEventSink runId >>= runWith effectiveTarget nullPersistenceHooks
    Just directory ->
      withRunStoreSeeded directory (manifest effectiveTarget owner) inherited $ \runStore -> do
        persistence <- persistenceFor runStore (printedValue prog) (length inherited)
        handlesEventSink [storeEventHandle runStore, stdout] runId >>= runWith effectiveTarget persistence
  where
    manifest effectiveTarget owner =
      RunManifest
        runId
        name
        runnerVersion
        (printedValue prog)
        (targetLabel effectiveTarget)
        (targetPolicy effectiveTarget)
        parent
        lineage
        owner
    runWith effectiveTarget persistence actualSink = do
      let runtimeControls = case control of
            Nothing -> Nothing
            Just (MachineControl controls _ _) -> Just controls
          sink = case control of
            Nothing -> actualSink
            Just (MachineControl _ _ deferredSink) -> deferredSink
      case control of
        Nothing -> actualSink (RunStarted name (targetLabel effectiveTarget))
        Just (MachineControl _ deferred _) -> do
          activated <- activateEventSink deferred actualSink (RunStarted name (targetLabel effectiveTarget))
          unless activated (ioError (userError "machine event sink was activated twice"))
      -- Machine events are the trace. Human narration would duplicate full,
      -- input-expanded prompts into diagnostic stderr.
      let run =
            runCmdControlled
              runtimeControls
              persistence
              sink
              (const (pure ()))
              reg
              name
              effectiveTarget
              prog
              gs
      outcome <- try run
      case outcome of
        Right tr -> sink (RunCompleted (billExecFresh tr) (billMemo tr))
        Left (e :: SomeException)
          | Just (MachineCancelled why) <- fromException e -> do
              sink (RunCancelled (T.pack why))
              throwIO (ExitFailure 130)
          | Just (_ :: SomeAsyncException) <- fromException e ->
              sink (RunCancelled (T.pack (displayException e))) >> throwIO e
          | otherwise ->
              sink (RunFailed (machineFailureClass e) (T.pack (displayException e))) >> throwIO e

machineControlHandle :: IO (Maybe Handle)
machineControlHandle = do
  descriptor <- lookupEnv "AGENT_CAT_CONTROL_FD"
  legacy <- (== Just "1") <$> lookupEnv "AGENT_CAT_CONTROL_STDIN"
  case (descriptor, legacy) of
    (Just _, True) -> ioError (userError "AGENT_CAT_CONTROL_FD and AGENT_CAT_CONTROL_STDIN cannot both select the control channel")
    (Nothing, True) -> pure (Just stdin)
    (Nothing, False) -> pure Nothing
    (Just value, False) -> case readMaybe value of
      Just descriptorNumber | descriptorNumber >= (3 :: Int) -> Just <$> fdToHandle (Fd (fromIntegral descriptorNumber))
      _ -> ioError (userError ("AGENT_CAT_CONTROL_FD must be a decimal file descriptor at least 3, not '" <> value <> "'"))

persistenceFor :: RunStore -> Value -> Int -> IO PersistenceHooks
persistenceFor store program inheritedAnswers = do
  counts <- newIORef (inheritedAnswers, 0 :: Int)
  pure
    PersistenceHooks
      { persistenceLookupAnswer = \question ->
          fmap (\answer -> (answerValue answer, if answerReplaced answer then "replacement" else "persistent"))
            <$> lookupStoredAnswer store question,
        persistenceStoreAnswer = \occurrence question answer replayable ->
          when replayable $ do
            storeReusableAnswer store (AnswerRecord question answer occurrence True False)
            atomicModifyIORef' counts (\(answers, effects) -> ((answers + 1, effects), ())),
        persistenceStartEffect = \occurrence question ->
          appendEffectRecord store (EffectRecord question Nothing occurrence EffectStarted),
        persistenceCompleteEffect = \occurrence question answer -> do
          appendEffectRecord store (EffectRecord question (Just answer) occurrence EffectCompleted)
          atomicModifyIORef' counts (\(answers, effects) -> ((answers, effects + 1), ())),
        persistenceCheckpoint = \occurrence -> do
          (answers, effects) <- readIORef counts
          writeCheckpoint store (Checkpoint program (Just occurrence) answers effects)
      }

resolveTargetForProgram :: Target -> ProgramOf r -> Either Text Target
resolveTargetForProgram Scripted _ = Right Scripted
resolveTargetForProgram target@(Routed rr) _ | rrV2Frozen rr = Right target
resolveTargetForProgram (Routed rr) prog = do
  authored <- servedChains (progRawOut prog)
  resolved <- case rrSelectedRoutingV2 rr of
    Nothing -> resolveRoutingConfig (loadedRouting (rrRouting rr)) (rrCommandRoutes rr) authored
    Just selected -> expandRoutingConfigV2 selected (rrRealizeOverrides rr) (rrCommandRoutes rr) authored
  pure
    ( Routed
        rr
          { rrRoutes = resolvedRoutes resolved,
            rrRealizations = resolvedRealizations resolved
          }
    )

-- | Resolve secrets and inventories only after the run-fact/routing fixed point.
-- The resulting target is immutable and safe to persist before any child starts.
finalizeTargetForProgram :: Target -> ProgramOf r -> IO (Either Text Target)
finalizeTargetForProgram Scripted _ = pure (Right Scripted)
finalizeTargetForProgram target@(Routed rr) _ | rrV2Frozen rr = pure (Right target)
finalizeTargetForProgram (Routed rr) prog = case rrSelectedRoutingV2 rr of
  Nothing -> pure (resolveTargetForProgram (Routed rr) prog)
  Just selected
    | any credentialArgument (rrAdapterArgs rr) ->
        pure (Left "credential-bearing adapter argv is forbidden for version-2 routing; use an environment secret reference")
    | otherwise -> do
        ambient <- Map.fromList <$> getEnvironment
        case do
          authored <- servedChains (progRawOut prog)
          expanded <- expandRoutingConfigV2 selected (rrRealizeOverrides rr) (rrCommandRoutes rr) authored
          let required = nub (map (routerName . resolvedRouter) (Map.elems (resolvedRealizations expanded)))
          contexts <- resolveEngineContexts selected required ambient
          pure (expanded, required, contexts) of
          Left problem -> pure (Left problem)
          Right (expanded, required, contexts) -> do
            cacheHome <- routingCacheHome
            now <- getCurrentTime
            discovered <- discoverRoutingInventories (rrDiscoveryMode rr) cacheHome now selected contexts required
            pure $ do
              inventories <- discovered
              frozen <- freezeRoutingConfigV2 selected inventories expanded
              let childEnvironments =
                    Map.fromList
                      [ (backend, resolvedEngineChildEnvironment context)
                        | context <- Map.elems contexts,
                          let backend = resolvedEngineBackend context,
                          BackendAcp _ <- [backend]
                      ]
              pure
                ( Routed
                    rr
                      { rrRoutes = resolvedRoutes frozen,
                        rrRealizations = resolvedRealizations frozen,
                        rrChildEnvironments = childEnvironments,
                        rrV2Frozen = True
                      }
                )

routingCacheHome :: IO FilePath
routingCacheHome = do
  configured <- lookupEnv "XDG_CACHE_HOME"
  case configured of
    Just path | not (null path) -> pure path
    _ -> (</> ".cache") <$> getHomeDirectory

credentialArgument :: String -> Bool
credentialArgument argument =
  any (`elem` credentialWords) (filter (not . T.null) (T.split (not . isAlphaNum) (T.toLower (T.pack argument))))
  where
    credentialWords =
      [ "apikey",
        "key",
        "auth",
        "authorization",
        "token",
        "secret",
        "password",
        "cookie",
        "credential"
      ]

targetLabel :: Target -> Text
targetLabel Scripted = "scripted"
targetLabel (Routed rr) = T.intercalate "," (map backendSpelling (routeBackends (rrRoutes rr)))

targetPolicy :: Target -> Value
targetPolicy Scripted = object ["kind" .= ("scripted" :: Text)]
targetPolicy (Routed rr) = case rrSelectedRoutingV2 rr of
  Nothing -> object baseFields
  Just selected ->
    let versionedFields =
          baseFields
            <> [ "routingVersion" .= (2 :: Int),
                 "persona" .= selectedPersonaName selected,
                 "personaSource" .= personaSelectionSourceName (selectedPersonaSource selected)
               ]
        policyWithoutDigest = object versionedFields
        digest = sha256Fingerprint (BL.toStrict (encode policyWithoutDigest))
     in object (versionedFields <> ["policyDigest" .= digest])
  where
    baseFields =
      [ "kind" .= ("routed" :: Text),
        "default" .= backendSpelling (routeDefault (rrRoutes rr)),
        "routes"
          .= [object ["name" .= name, "backend" .= backendSpelling backend] | (name, backend) <- routeNamed (rrRoutes rr)],
        "scratch" .= rrScratch rr,
        "adapterArgs" .= redactAdapterArgs (rrAdapterArgs rr),
        "binary" .= rrBinary rr,
        "pollMs" .= rrPollMs rr,
        "timeoutMs" .= rrTimeoutMs rr,
        "routingSources" .= map T.pack (loadedRoutingSources (rrRouting rr)),
        "realizations" .= map resolvedRealizationPolicy (Map.elems (rrRealizations rr)),
        "verbose" .= rrVerbose rr
      ]

lineagePolicy :: Value -> Value
lineagePolicy (Object policy) =
  Object
    ( update "realizations" normalizeRealizations
        (KM.delete "policyDigest" policy)
    )
  where
    normalizeRealizations (Array realizations) = Array (fmap normalizeRealization realizations)
    normalizeRealizations value = value
    normalizeRealization (Object realization) =
      Object (update "inventory" normalizeInventory realization)
    normalizeRealization value = value
    normalizeInventory (Object inventory) =
      Object (foldr KM.delete inventory ["source", "fetchedAt", "cacheAgeSeconds", "warning"])
    normalizeInventory value = value
    update key transform values =
      case KM.lookup key values of
        Nothing -> values
        Just value -> KM.insert key (transform value) values
lineagePolicy value = value

redactAdapterArgs :: [String] -> [Text]
redactAdapterArgs = go False
  where
    go _ [] = []
    go redactNext (arg : rest)
      | redactNext = "<redacted>" : go False rest
      | otherwise =
          let text = T.pack arg
              (key, value) = T.breakOn "=" text
           in if sensitive key
                then
                  if T.null value
                    then text : go True rest
                    else (key <> "=<redacted>") : go False rest
                else text : go False rest
    sensitive text = any (`T.isInfixOf` T.toLower text) ["token", "secret", "password", "api-key", "api_key", "authorization"]

machineFailureClass :: SomeException -> FailureClass
machineFailureClass e
  | Just engineError <- fromException e = case Engine.engineFailureKind engineError of
      Engine.TransportFailure -> FailureTransport
      Engine.ProtocolFailure -> FailureProtocol
  | Just (_ :: AcpError) <- fromException e = FailureTransport
  | Just (_ :: DeckError) <- fromException e = FailureTransport
  | Just (_ :: ExitCode) <- fromException e = FailureSetup
  | Just (_ :: IOError) <- fromException e = FailureRuntime
  | otherwise = FailureRuntime

-- ---------------------------------------------------------------------------
-- The transport configurations, and the facts they are read for
-- ---------------------------------------------------------------------------

-- | The per-run knobs, applied to a backend of the scheme they belong to.
--
-- Adapter names are resolved here, at the composition root; ACP itself receives
-- only an `AdapterSpec`.
--
-- It stands at the top level rather than inside 'runCmd' because
-- 'runFactsWith' reads it while the program and its run facts settle to one
-- routing table; deriving it twice is how a header and a fact disagree.
-- second derivation of the same policy, which is exactly how a header and a
-- fact come to disagree about one run.
acpConfigFor :: RunRoutes -> FilePath -> Text -> AcpConfig
acpConfigFor rr dir w =
  let base = adapterConfig (adapterSpecFor w) (rrAdapterArgs rr)
   in base
        { acpCwd = dir,
          acpTurnTimeoutMs = fromMaybe (acpTurnTimeoutMs base) (rrTimeoutMs rr),
          acpChildEnvironment = Map.findWithDefault inheritChildEnvironment (BackendAcp w) (rrChildEnvironments rr),
          acpVerbose = rrVerbose rr
        }

adapterSpecFor :: Text -> AdapterSpec
adapterSpecFor "stub" = stubAdapter
adapterSpecFor "claude" = claudeAdapter
adapterSpecFor "codex" = codexAdapter
adapterSpecFor "droid" = droidAdapter
adapterSpecFor name = pathAdapter name
-- | The @deck:@ half of 'acpConfigFor'.
--
-- It stands here for one of 'acpConfigFor''s two reasons and not both: nothing
-- new is decided, because 'Agentic.AgentDeck.defaultDeckConfig' already turns a
-- word into a backend. Its callers are all inside 'runCmd' — the world for a
-- @deck:@ backend and the two header arms that name one — because
-- @run.engine@'s @deck:@ half needs no config at all: a deck session's policy is
-- @'Agentic.Runtime.Facts.sessionPolicy' False@ by construction, and the poll and
-- timeout knobs this function applies are not part of it.
deckConfigFor :: RunRoutes -> Text -> DeckConfig
deckConfigFor rr s =
  let base = defaultDeckConfig s
   in base
        { deckBinary = fromMaybe (deckBinary base) (rrBinary rr),
          deckPollMs = fromMaybe (deckPollMs base) (rrPollMs rr),
          deckTimeoutMs = fromMaybe (deckTimeoutMs base) (rrTimeoutMs rr),
          deckVerbose = rrVerbose rr
        }

-- | The policy of an @acp:@ backend, in 'Agentic.Runtime.Facts.sessionPolicy''s
-- words: the one field that decides it, read once.
--
-- The header says it, twice, and @run.engine@ says it to the prompts. A second
-- spelling would be a run whose header and whose provenance paragraph described
-- different transports, which is the failure this whole mechanism exists to
-- remove — so the wording is not this module's, and a program that gates on it
-- ('Agentic.Runtime.Facts.sharesOneSession') matches the same bytes the operator
-- read.
acpSessionPolicy :: AcpConfig -> Text
acpSessionPolicy = sessionPolicy . acpFreshPerQuestion

-- | The policy of a @deck:@ backend, which is not a field but a consequence.
--
-- A 'DeckConfig' has no @freshPerQuestion@ to read and could not have one: the
-- engine sends into a live @agent-deck@ pane that somebody else started, so
-- there is no @session\/new@ for it to open and every question of the run lands
-- in the same conversation. That is 'Agentic.Runtime.Facts.sessionPolicy' at 'False',
-- and it is a CAF rather than a literal so the header and @run.engine@ cannot
-- come to describe one pane two ways.
deckSessionPolicy :: Text
deckSessionPolicy = sessionPolicy False

-- | __The facts this run knows about itself before it puts a question__, as the
-- texts 'Agentic.Runtime.Facts.runFacts' binds.
--
-- All four are properties of the command line and of the clock, which is what
-- lets them be inputs: an input is bound when the program is built, and nothing
-- here has to wait for an adapter to start or a question to be answered. The
-- working directory is deliberately not among them — it is settled in 'runCmd',
-- after this — and 'acpSessionPolicy' does not read it, which is why passing
-- @\".\"@ to 'acpConfigFor' below states the same policy the run will state.
--
-- __What each one is worth to a prompt.__ @run.backends@ and @run.engine@ are
-- the two facts a reporting model was previously told to leave as conditionals,
-- because the run's header is terminal output and no party receives it; bound
-- here, a provenance paragraph can say what happened instead of what cannot be
-- known from inside it. @run.sentinel@ is the premise an independence probe was
-- asserting without anybody having established it: a line generated for this run
-- and put nowhere the runner does not put it.
--
-- __@run.routes@ is worth what neither of the other two can say__: /which/
-- answerer a given pin reached. @run.backends@ is deduplicated and carries no
-- names, so no arithmetic over it distinguishes a run whose evaluator sits in a
-- pane of its own from one where evaluator and workers share the pane; and
-- @run.engine@ says only whether /some/ answerer shares a conversation, never
-- which. A program that must assert "the judge is somewhere the work is not"
-- reads both, through 'Agentic.Runtime.Facts.routedBackend' and
-- 'Agentic.Runtime.Facts.sharesOneSession', and neither fact derives the other.
--
-- __@run.engine@ is read as well as printed__, which is why both its halves come
-- from 'Agentic.Runtime.Facts.sessionPolicy' and neither is a literal here: a program
-- gates on 'Agentic.Runtime.Facts.sharesOneSession', and the value it matches has to
-- be the value the operator saw in the header. Before that, the @deck:@ half was
-- a sentence written in this function and the header's @deck:@ arm was a
-- different one, so one pane had two descriptions and only one of them could be
-- matched.
runFactsWith :: Registry -> Text -> Target -> Text -> [(Text, Text)]
runFactsWith reg name target sentinel =
  [ (runFactBackends, backendsFact),
    (runFactEngine, engineFact),
    (runFactRoutes, routesFact tableOf),
    (runFactSentinel, sentinel)
  ]
  where
    -- The table, or the absence of one. `routesFact` takes this rather than the
    -- `Target` so that the fact cannot come to depend on `--poll`.
    tableOf = case target of
      Scripted -> Nothing
      Routed rr -> Just (rrRoutes rr)

    backendsFact = case target of
      -- No colon in this arm, and one in the other two: a fact is spliced after
      -- a label a prompt wrote ("Backends: …"), and "Backends: no backend: …"
      -- reads as a mistake. The count leads in every arm, which is what a
      -- reader is looking for.
      Scripted ->
        [wft|no backend at all -- every question is answered from this program's own table of |]
          <> tshow (length (maybe [] rowScript (regLookup reg name)))
          <> " canned replies, and nothing is reached"
      Routed rr -> case routeBackends (rrRoutes rr) of
        [b] -> "1 backend: " <> backendSpelling b
        bs ->
          tshow (length bs)
            <> " backends: "
            <> T.intercalate ", " (map backendSpelling bs)

    -- Derived from the very fields the header prints, and from nothing else.
    -- The mixed table earns its own arm rather than a hedge: a run that is half
    -- `acp:` and half `deck:` has two session policies, and a prompt told only
    -- one of them would be told a falsehood about half its answers.
    engineFact = case target of
      Scripted -> "scripted: a canned table, no process and no session"
      Routed rr ->
        let bs = routeBackends (rrRoutes rr)
            acps = [w | BackendAcp w <- bs]
            decks = [s | BackendDeck s <- bs]
            acpWords = case acps of
              (w : _) -> "acp: " <> acpSessionPolicy (acpConfigFor rr "." w)
              [] -> ""
            -- The session id is deliberately not spliced: what a prompt is
            -- owed is the policy, and a pane's title is neither a policy nor
            -- something a report should be repeating.
            deckWords = "deck: " <> deckSessionPolicy
         in case (acps, decks) of
              (_ : _, []) -> acpWords
              ([], _ : _) -> deckWords
              (_ : _, _ : _) -> acpWords <> "; " <> deckWords
              -- `routeBackends` always has the default, so this is
              -- unreachable; it is written rather than left to a partial
              -- pattern match.
              ([], []) -> "no engine: this run reaches nothing"

-- | @run.routes@ — __the route table as this run resolved it__, one line per
-- answerer: the label, @\" = \"@, and 'backendSpelling'.
--
-- > (default) = deck:0f3a91c2-codex
-- > partner = deck:7b2e40aa-claude
--
-- Derived from the very table the header prints and from nothing else: the same
-- 'routeDefault'-then-'routeNamed' order 'routeBackends' and @sayManyBackends@
-- use, so an operator can read the fact against the header against their own
-- command line, and 'backendSpelling' for every right-hand side, which is
-- documented as the printed inverse of 'parseBackend' — so the fact round-trips
-- and a gate reading it is reading the operator's own word rather than a second
-- rendering of it.
--
-- __It does not deduplicate.__ 'routeBackends' does, because a header that
-- counted route lines would overstate how many agents a run started; this fact
-- is the /mapping/, and two pins on one backend is precisely the thing a gate
-- over it must be able to see.
--
-- __The default line is present on every live run, @--route@ or no @--route@.__
-- That is the one thing that makes the fact decidable where it matters: a run
-- with @--session A@ and nothing else still has an answerer, and
-- @(default) = deck:A@ is the single line that distinguishes it from the split
-- where a judge's pin is routed away. Omit it and the two read alike, and the
-- refusal that should have fired would not.
--
-- __It is empty exactly when there is no table__ — @--scripted@, and the two
-- static verbs, which bind no run fact at all. Empty means /no table/, not /no
-- @--route@/, and 'Agentic.Workflow.routedBackend' reads it as the empty text
-- for the reason 'Agentic.Workflow.sharesOneSession' reads an unbound engine as
-- 'False'.
--
-- It stands at the top level, exported, and takes the /table/ rather than the
-- 'Target', for two reasons. The first is 'acpConfigFor''s second reason: the
-- policy gate holds it against 'Agentic.Workflow.routedBackend' — the fact and
-- its one reader, checked as one contract, exactly as @run.engine@ and
-- 'Agentic.Workflow.sharesOneSession' are, and a fact whose derivation lived
-- inside a @where@ could only be checked through a transport. The second is that
-- the argument is then exactly what the fact depends on: @'Nothing'@ is /no
-- table/, and nothing here can come to depend on @--poll@.
routesFact :: Maybe (Routes Backend) -> Text
routesFact = \case
  Nothing -> ""
  Just rs ->
    T.unlines
      [ label <> " = " <> backendSpelling b
      | (label, b) <- (routeDefaultLabel, routeDefault rs) : routeNamed rs
      ]

-- | The line this run generates for itself, and puts nowhere else.
--
-- __The claim it supports is run-uniqueness__, and the clock is what makes it
-- true: 'getMonotonicTimeNSec' is strictly increasing while the host is up, so
-- no two runs on this machine read the same value, and nothing that has not been
-- shown the line can produce it — an uptime to the nanosecond is not something
-- a model knows. It is the same clock 'freshScratch' reads, for the same reason,
-- and reading a second source of uniqueness would be two answers to one
-- question.
--
-- __It is not a secret and does not need to be.__ Nothing is authorized by it.
-- What it is for is a probe that can only be answered by an answerer that has
-- seen it, which makes \"I have not seen this before\" a statement with content
-- where before there was nothing to have seen.
freshSentinel :: IO Text
freshSentinel = do
  stamp <- getMonotonicTimeNSec
  pure ("PARENT_HISTORY_SENTINEL=" <> tshow stamp)

-- | A directory of this run's own, under the system temporary directory, for a
-- @--engine acp@ run that named none.
--
-- Every run acts somewhere: a workflow may end in an act that writes, and
-- 'Agentic.Acp.permissionByIntent' authorizes an effect's tool call /in the session's
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
--
-- __The order of the arms is the whole of the collision policy.__ Every arm
-- @help@ added stands where a verb in head position has already been decided,
-- so a row named @plan@, @cost@, @run@, @list@ or @help@ is unreachable /by
-- name/ rather than ambiguous — and unreachable-but-registered is a thing a
-- gate can shout about, which both gates do, against @list@'s own output. The
-- four verbs that predate this are untouched: @list --help@ still says @list
-- takes nothing but --json@, and @plan --help@ still refuses @--help@ as a name
-- and lists the rows. Both are verb arms, both already answer usefully, and
-- touching either would touch a verb three shell gates read.
--
-- The last two arms are the new ones that are /not/ a verb: @NAME --help@,
-- which is unconditional in the name (so @harden --help@ and @hardne --help@
-- both reach 'Help', and the second gets the list of rows rather than @no
-- verb@), and a bare registered name, which is refused.
parseCommand :: Registry -> [Text] -> Either Text Command
parseCommand reg = \case
  [] -> Left (usage reg)
  ["--help"] -> Right Usage
  ("--routing" : rest) -> routingOptions Human Nothing DiscoveryNormal rest
  ["--migrate-routing"] -> Left "--migrate-routing takes SOURCE --output DESTINATION"
  ("--migrate-routing" : source : rest) -> case rest of
    ["--output", destination] -> Right (MigrateRouting (T.unpack source) (T.unpack destination))
    _ -> Left "--migrate-routing takes SOURCE --output DESTINATION"
  ["help"] -> Right Usage
  ["help", name] -> Right (Help name)
  ("help" : _) ->
    Left ("help takes one " <> regNoun reg <> " and nothing else\n\n" <> usage reg)
  ["list"] -> Right (List Human)
  ["list", "--json"] -> Right (List Json)
  ("list" : _) -> Left ("list takes nothing but --json\n\n" <> usage reg)
  [verb]
    | verb `elem` verbs ->
        Left (verb <> " needs " <> article reg <> ": " <> T.intercalate " or " (regNames reg))
  ("plan" : name : rest) -> planOpts name Human False False [] rest
  ("cost" : name : rest) -> costOpts name [] rest
  ("run" : name : rest) -> (\(t, p, ins) -> Run name t p ins) <$> parseTarget reg rest
  ("machine" : runIdText : name : rest) -> do
    runId <- mkRunId runIdText
    (target, pinned, inputs) <- parseTarget reg rest
    pure (Machine runId name target pinned inputs)
  ("lineage-check" : operation : parent : name : rest) -> do
    lineage <- case operation of
      "restart" -> Right RestartRun
      "resume" -> Right ResumeRun
      "fork" -> Right ForkRun
      _ -> Left "lineage-check operation must be restart, resume, or fork"
    (edits, targetArgs) <- lineageEdits lineage rest
    (target, pinned, inputs) <- parseTarget reg targetArgs
    pure (LineageCheck lineage (T.unpack parent) edits name target pinned inputs)
  ("machine-restart" : runIdText : parent : name : rest) -> lineageCommand RestartRun runIdText parent name rest
  ("machine-resume" : runIdText : parent : name : rest) -> lineageCommand ResumeRun runIdText parent name rest
  ("machine-fork" : runIdText : parent : name : rest) -> lineageCommand ForkRun runIdText parent name rest
  [name, "--help"] -> Right (Help name)
  [name] | isJust (regLookup reg name) -> Left (bareRow reg name)
  (verb : _) -> Left ("no verb '" <> verb <> "'\n\n" <> usage reg)
  where
    -- Still three. `help` is not among them because `help` alone is a request
    -- that has an answer — the usage — where `plan` alone is a verb missing its
    -- subject.
    verbs = ["plan", "cost", "run", "machine", "lineage-check", "machine-restart", "machine-resume", "machine-fork"]

    routingOptions rendering persona mode = \case
      [] -> Right (RoutingInspection rendering persona mode)
      "--json" : rest
        | rendering == Json -> Left "--routing received --json twice"
        | otherwise -> routingOptions Json persona mode rest
      "--persona" : value : rest
        | isJust persona -> Left "--routing received --persona twice"
        | T.null (T.strip value) -> Left "--persona takes a non-empty name"
        | otherwise -> routingOptions rendering (Just value) mode rest
      "--offline" : rest
        | mode /= DiscoveryNormal -> Left "--offline and --refresh-models are mutually exclusive and may appear only once"
        | otherwise -> routingOptions rendering persona DiscoveryOffline rest
      "--refresh-models" : rest
        | mode /= DiscoveryNormal -> Left "--offline and --refresh-models are mutually exclusive and may appear only once"
        | otherwise -> routingOptions rendering persona DiscoveryRefresh rest
      ["--persona"] -> Left "--persona takes a name"
      flag : _ -> Left ("no option '" <> flag <> "' for --routing")

    lineageCommand lineage runIdText parent name rest = do
      runId <- mkRunId runIdText
      (edits, targetArgs) <- lineageEdits lineage rest
      (target, pinned, inputs) <- parseTarget reg targetArgs
      pure (MachineLineage lineage runId (T.unpack parent) edits name target pinned inputs)

    lineageEdits lineage args = do
      (edits, remaining) <- extractEdits [] args
      if lineage /= ForkRun && not (null edits)
        then Left "answer edits are valid only for fork"
        else Right (edits, remaining)

    extractEdits edits ("--drop-answer" : occurrence : rest) = do
      parsed <- ForkDrop <$> parseOccurrenceArg occurrence
      extractEdits (edits <> [parsed]) rest
    extractEdits edits ("--set-answer" : specification : rest) = do
      let (occurrence, suffix) = T.breakOn "=" specification
      if T.null occurrence || T.null suffix
        then Left "--set-answer expects OCCURRENCE_ID=JSON_FILE"
        else do
          parsed <- parseOccurrenceArg occurrence
          extractEdits (edits <> [ForkReplace parsed (T.unpack (T.drop 1 suffix))]) rest
    extractEdits edits (arg : rest) = do
      (more, remaining) <- extractEdits [] rest
      Right (edits <> more, arg : remaining)
    extractEdits edits [] = Right (edits, [])

    parseOccurrenceArg text = case (TR.decimal text :: Either String (Integer, Text)) of
      Right (value, suffix)
        | T.null suffix, value <= toInteger (maxBound :: Word64) -> Right (OccurrenceId (fromInteger value))
      _ -> Left "fork occurrence id must be an unsigned Word64 decimal string"

    -- Three independent flags, so they are folded rather than enumerated: the
    -- same three spelled in any other order are the same request. In particular
    -- `--raw --json` is a request for both and gets both, the printed program
    -- arriving under `program` — the flag says which program to print and
    -- `--json` says who is reading, and neither answers the other's question.
    planOpts :: Text -> Render -> Bool -> Bool -> [InputFlag] -> [Text] -> Either Text Command
    planOpts name rendering raw pinned ins args = case args of
      [] -> Right (Plan name rendering raw pinned ins)
      ("--raw" : more) -> planOpts name rendering True pinned ins more
      ("--require-pinned" : more) -> planOpts name rendering raw True ins more
      ("--json" : more) -> planOpts name Json raw pinned ins more
      _
        | Just taken <- takeInput args ->
            taken >>= \(f, more) -> planOpts name rendering raw pinned (ins <> [f]) more
      (flag : _) ->
        Left
          ( "no option '"
              <> flag
              <> "' for plan, which takes "
              <> article reg
              <> " " <> [wft|and, at most, --raw, --require-pinned, --json and the input flags|] <> "\n\n"
              <> usage reg
          )

    costOpts :: Text -> [InputFlag] -> [Text] -> Either Text Command
    costOpts name ins args = case args of
      [] -> Right (Cost name ins)
      _
        | Just taken <- takeInput args ->
            taken >>= \(f, more) -> costOpts name (ins <> [f]) more
      _ -> Left ("cost takes " <> article reg <> " and its inputs, and nothing else\n\n" <> usage reg)

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
    roPersona :: !(Maybe Text),
    roRealizations :: ![Text],
    roDiscoveryMode :: !(Maybe DiscoveryMode),
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
noRunOpts =
  RunOpts
    { roScripted = False,
      roEngine = Nothing,
      roSession = Nothing,
      roBinary = Nothing,
      roPollMs = Nothing,
      roTimeoutMs = Nothing,
      roVerbose = False,
      roAdapter = Nothing,
      roAdapterArgs = [],
      roRoutes = [],
      roPersona = Nothing,
      roRealizations = [],
      roDiscoveryMode = Nothing,
      roScratch = Nothing,
      roRequirePinned = False,
      roInputs = []
    }

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
                <> [wft|': --engine takes acp (start an adapter and speak the protocol to it) or deck (send to a live agent-deck session)|]
      ("--session" : v : rest) -> go o {roSession = Just v} rest
      ("--binary" : v : rest) -> go o {roBinary = Just v} rest
      ("--adapter" : v : rest) -> go o {roAdapter = Just v} rest
      ("--adapter-arg" : v : rest) -> go o {roAdapterArgs = roAdapterArgs o <> [v]} rest
      ("--route" : v : rest) -> go o {roRoutes = roRoutes o <> [v]} rest
      ("--persona" : v : rest)
        | isJust (roPersona o) -> Left "--persona may appear only once"
        | T.null (T.strip v) -> Left "--persona takes a non-empty name"
        | otherwise -> go o {roPersona = Just v} rest
      ("--realize" : v : rest) -> go o {roRealizations = roRealizations o <> [v]} rest
      ("--offline" : rest) -> setDiscovery o DiscoveryOffline rest
      ("--refresh-models" : rest) -> setDiscovery o DiscoveryRefresh rest
      [flag]
        | flag `elem` ["--persona", "--realize"] -> Left (flag <> " takes a value")
      ("--scratch" : v : rest) -> go o {roScratch = Just v} rest
      -- Refused by name rather than by the fallthrough below, because the
      -- operator asking for it is asking a coherent question with a real
      -- answer: a run's machine-readable record is the trace it prints as it
      -- happens — every question, every answer, both bills — and a summary
      -- object would be this runner inventing one.
      ("--json" : _) ->
        Left
          [wft|run takes no --json: a run's record is the trace it prints as it happens, and there is no summary of one this runner would not be inventing|]
      ("--poll" : v : rest) -> withMs "--poll" v (\n -> go o {roPollMs = Just n} rest)
      ("--timeout" : v : rest) -> withMs "--timeout" v (\n -> go o {roTimeoutMs = Just n} rest)
      (flag : _) -> Left ("no option '" <> flag <> "' for run\n\n" <> usage reg)

    withMs :: Text -> Text -> (Int -> Either Text a) -> Either Text a
    withMs flag v k = case readMaybe (T.unpack v) of
      Just n | n >= 0 -> k n
      _ -> Left (flag <> " takes a number of milliseconds, not '" <> v <> "'")

    setDiscovery o mode rest = case roDiscoveryMode o of
      Nothing -> go o {roDiscoveryMode = Just mode} rest
      Just _ -> Left "--offline and --refresh-models are mutually exclusive and may appear only once"

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
      [wft|--engine acp starts an adapter of its own, and --session sends to an agent-deck session somebody else started; pick one|]
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
          [wft|--route refines this run's default answerer, and there is none: give --engine acp or --session <id> as well|]
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
    routingFlags =
      [ ("--persona", isJust (roPersona o)),
        ("--realize", not (null (roRealizations o))),
        ("--offline", roDiscoveryMode o == Just DiscoveryOffline),
        ("--refresh-models", roDiscoveryMode o == Just DiscoveryRefresh)
      ]
    liveFlags = acpFlags <> deckFlags <> routingFlags <> [("--timeout", isJust (roTimeoutMs o)), ("--verbose", roVerbose o)]

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
      realized <- traverse parseRealize (roRealizations o)
      case firstDuplicate (map fst realized) of
        Just axis -> Left ("--realize names axis '" <> axis <> "' twice")
        Nothing -> Right ()
      let table = routes def named
      forbidForeign (Set.fromList (map schemeOf (routeBackends table)))
      pure . Routed $
        RunRoutes
          { rrRoutes = table,
            rrCommandRoutes = table,
            rrRouting = LoadedRouting emptyRoutingConfig [] Nothing Nothing,
            rrSelectedRoutingV2 = Nothing,
            rrPersonaOverride = roPersona o,
            rrRealizeOverrides = Map.fromList realized,
            rrDiscoveryMode = fromMaybe DiscoveryNormal (roDiscoveryMode o),
            rrChildEnvironments = Map.empty,
            rrV2Frozen = False,
            rrRealizations = Map.empty,
            rrScratch = T.unpack <$> roScratch o,
            rrAdapterArgs = map T.unpack (roAdapterArgs o),
            rrBinary = T.unpack <$> roBinary o,
            rrPollMs = roPollMs o,
            rrTimeoutMs = roTimeoutMs o,
            rrVerbose = roVerbose o,
            rrAdapterGiven = isJust (roAdapter o)
          }

    parseRealize value = case T.breakOn "=" value of
      (axis, suffix)
        | not (T.null axis), Just alias <- T.stripPrefix "=" suffix, not (T.null alias) -> Right (axis, alias)
      _ -> Left ("--realize takes AXIS=MODEL-ALIAS, not '" <> value <> "'")

-- | Usage's human registry catalog. Names are command syntax and stay whole;
-- only their prose yields to the fixed terminal width.
usageCatalog :: Registry -> Text
usageCatalog reg = T.intercalate "\n" (heading : map line rows)
  where
    rows = regRows reg
    nameWidth = maximum (1 : map (T.length . fst) rows)
    heading = "  <" <> regNoun reg <> "> is one of:"

    line (name, row) =
      let prefix = "  " <> T.justifyLeft nameWidth ' ' name <> "  "
       in prefix <> shorten (80 - T.length prefix) (rowDoc row)

    shorten limit text
      | T.length text <= limit = text
      | limit <= 0 = ""
      | limit == 1 = "…"
      | otherwise =
          let clipped = T.take (limit - 1) text
              complete = T.stripEnd (fst (T.breakOnEnd " " clipped))
              stem
                | T.take 1 (T.drop (limit - 1) text) == " " = T.stripEnd clipped
                | T.null complete = clipped
                | otherwise = complete
           in stem <> "…"

usage :: Registry -> Text
usage reg =
  T.intercalate
    "\n"
    [ bin <> " — " <> regBanner reg,
      "",
      "  " <> bin <> " list [--json]",
      "  " <> bin <> " --routing [--json] [--persona NAME] [--offline | --refresh-models]",
      "  " <> bin <> " --migrate-routing SOURCE --output DESTINATION",
      "  " <> bin <> " help <" <> noun <> ">",
      "  " <> bin <> " <" <> noun <> "> --help",
      "  " <> bin <> " plan <" <> noun <> "> [--raw] [--require-pinned] [--json] [<input>...]",
      "  " <> bin <> " cost <" <> noun <> "> [<input>...]",
      "  " <> bin <> " run  <" <> noun <> "> --scripted [<input>...] [< stdin]",
      "  " <> bin <> " machine <run-id> <" <> noun <> "> <run options>",
      "  " <> bin <> " lineage-check restart|resume|fork <store> <" <> noun <> "> <run options>",
      "  " <> bin <> " machine-restart <run-id> <parent-store> <" <> noun <> "> <run options>",
      "  " <> bin <> " machine-resume  <run-id> <parent-store> <" <> noun <> "> <run options>",
      "  " <> bin <> " machine-fork    <run-id> <parent-store> <" <> noun <> "> <run options>",
      runLead <> "--session <id> [--binary PATH] [--poll MS]",
      under (runLead <> "--session <id> ") <> "[--route NAME=BACKEND]...",
      under (runLead <> "--session <id> ") <> "[--timeout MS] [--verbose]",
      runLead <> "--engine acp",
      under runLead <> "[--adapter stub|claude|codex|droid|PATH]",
      under (runLead <> "--engine acp ") <> "[--adapter-arg ARG]... [--scratch DIR]",
      under (runLead <> "--engine acp ") <> "[--route NAME=BACKEND]...",
      under (runLead <> "--engine acp ") <> "[--timeout MS] [--verbose]",
      under runLead <> "[--persona NAME] [--realize AXIS=MODEL-ALIAS]...",
      under runLead <> "[--offline | --refresh-models]",
      "",
      usageCatalog reg,
      "",
      "  help prints one " <> noun <> "'s own page: what it is for, what each of",
      "  its inputs means, which transport it wants, a worked command line and a",
      "  rehearsal. It spends nothing and asks nobody. Both spellings above print",
      "  the same page; a bare <" <> noun <> "> with no verb is refused, because it",
      "  is ambiguous between telling you about it and doing it.",
      "",
      "  <input> is one of the three explicit flags below. A program that takes",
      "  inputs is a program of them: each is a define supplied at run time and",
      "  spliced into prompts as data. An author may mark one input as command-tail",
      "  data and one as standard input; their default names are args and input.",
      "  plan and cost leave missing values empty; run requires every input.",
      "",
      "  An input named run.<something> is a RUN FACT and is not yours to give:",
      "  run binds it from the run it is making and no flag can. There are four —",
      "  run.backends, run.engine, run.routes and run.sentinel — and a program that",
      "  takes one still takes it from run, so the flags below name only your own.",
      "",
      "  --input FILE   the sole input of a program that takes exactly one, read",
      "                 from a file. Takes no NAME=, so a path containing = is",
      "                 never misread",
      "  --input-file NAME=FILE",
      "                 that input, read from a file. Repeatable",
      "  --input-arg NAME=VALUE",
      "                 that input, inline. Repeatable. A tilde straight after the",
      "                 = is expanded by bash and left as the character ~ by zsh,",
      "                 so what arrives depends on the shell — write \"$HOME/...\"",
      "                 when you mean your home directory and it arrives the same",
      "                 either way",
      "                 (files are strict UTF-8. An ordinary input strips one final",
      "                 newline as before; command-tail and stdin inputs preserve",
      "                 exact decoded text. Invalid UTF-8 refuses before the run)",
      "  standard input A declared stdin input is read to EOF when run did not get",
      "                 that name from an explicit flag. A terminal refuses instead",
      "                 of waiting. Explicit --input-arg/--input-file takes precedence",
      "  --routing      inspect resolved routing without starting an engine; --json",
      "                 is the sanitized frontend contract",
      "  --migrate-routing SOURCE --output DESTINATION",
      "                 create, but never overwrite, an equivalent offline v2 user file",
      "  --persona NAME select a v2 routing context explicitly; precedence is command",
      "                 line, AGENT_CAT_PERSONA, project selector, then user default",
      "  --realize AXIS=MODEL-ALIAS",
      "                 replace one managed v2 axis with an allowed concrete alias",
      "  --offline       use permitted model caches or static exact selectors only",
      "  --refresh-models force catalogue refresh and refuse if it fails",
      "  --json         print one object per row (list), one object (plan), or the",
      "                 instead of the prose, for a program that drives this CLI.",
      "                 The key names are an interface and are documented in the",
      "                 Agentic.Cli haddock; `inputs` names exactly the inputs a",
      "                 command line may give. cost takes none (plan --json has",
      "                 both of its numbers) and neither does run (its record is",
      "                 the trace). With --raw, plan --json adds the program",
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
      "                 PATH and then at machine-local pins; droid runs `droid exec",
      "                 --output-format acp` from PATH; anything else is a path.",
      "                 --engine acp only",
      "  --adapter-arg  one argument for the adapter's argv; repeatable.",
      "                 `--adapter-arg --refuse` is how the stub is told to answer *no*",
      "                 to a person's yes/no question. --engine acp only",
      "  --scratch      run in DIR instead of a fresh temporary directory: where the",
      "                 adapter is started, and the only place an act may write.",
      "                 Give --scratch \"$PWD\" whenever the run is meant to touch",
      "                 your own tree — without it the acts land in a temporary",
      "                 directory and your tree is untouched. --engine acp only",
      "  --route        NAME=BACKEND — put the questions this run pins to the model",
      "                 NAME to BACKEND instead of to the default answerer.",
      "                 Repeatable, at most once per NAME. BACKEND is",
      "                 acp:stub|claude|codex|droid|PATH (start this run's adapter)",
      "                 own) or deck:<id> (send to a live agent-deck session).",
      "                 NAME is a *serving model* — a `served by` pin or one of its",
      "                 spares — and not a party: routing the pin is what makes a",
      "                 fail-over ladder cross providers. A pinned model no --route",
      "                 names, every unpinned ask, and every tool and person take",
      "                 the default. Refuses a NAME this program never pins",
      "  routing YAML   live commands automatically load routing.yaml:",
      "                 user first, then the nearest project file.",
      "                 Profiles map symbolic servedBy names to ordered concrete",
      "                 ACP/deck realizations; --route overrides a primary backend.",
      "                 See Model definitions in cli/README.md",
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

-- | One JSON document, on one line, and nothing else on the stream.
--
-- __Encoded by @aeson@ and not by 'prettyJson'__, which is this module's other
-- renderer of a 'Value' and is the wrong one here: it is a /human/ rendering,
-- indented for reading beside a plan, and its string escape is
-- "Agentic.Observe"'s, which spells a character outside the basic plane as a
-- single five-digit @\\u@ escape no JSON parser will read back. A blurb is
-- prose and prose acquires an emoji eventually. The contract is that this
-- parses, so the encoder is the one that guarantees it.
--
-- Decoded back to 'Text' rather than written as bytes so that every line this
-- executable prints goes out through 'say' and one handle configuration;
-- 'encode' emits UTF-8, so the lenient decode never substitutes anything.
sayJson :: Value -> IO ()
sayJson = say . decodeUtf8Lenient . BL.toStrict . encode

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
