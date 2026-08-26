-- | The Lean oracle, as a subprocess that answers questions.
--
-- @conformance-oracle@ (@conformance\/Conformance.lean@) speaks line-delimited
-- JSON on stdin and stdout: one request per line, one reply per line, the
-- request's @id@ echoed verbatim, EOF on stdin the clean shutdown
-- (@doc\/conformance-schema.md@). This module is that protocol and nothing
-- else — it sends 'Value's and returns 'Value's, and forms no opinion about
-- whether a reply is right. Deciding that is the caller's job (@bisim@), and
-- keeping the two apart is what lets a transport failure be reported as a
-- transport failure instead of as a conformance divergence.
--
-- == The three requests
--
-- 'oracleProgram' observes a program under a list of worlds, 'oracleString'
-- asks one string-layer question, 'oraclePing' checks that the process is
-- alive and talking. Each returns the reply object with its @id@ __removed__,
-- because the id is bookkeeping in this module and would otherwise show up as
-- an unexpected key in every comparison the caller makes.
--
-- == What can go wrong, and what it looks like
--
-- Five things, and each has its own constructor of 'OracleError' rather than a
-- string: the binary is missing ('OracleMissing'); it does not answer within
-- the read timeout ('OracleTimeout'); it closed the pipe or died
-- ('OracleClosed'); it wrote something that is not JSON ('OracleUnreadable');
-- or it answered a question that was not the one asked ('OracleDesync').
--
-- The last two are the important ones. A reply whose @id@ is not the id sent
-- means the two sides have lost their place in the stream, and every
-- subsequent comparison would be comparing an answer against the wrong
-- question — which is not a conformance failure, but would be reported as
-- hundreds of them. So the first such error __poisons the connection__: the
-- error is recorded, and every later request fails with it immediately rather
-- than reading a stream that no longer means anything. A caller that sees an
-- 'OracleError' should stop, not continue.
--
-- The read timeout ('withOracle' uses 60 seconds) is the guard against a
-- wedged oracle, not against a slow program: a program request carries
-- @budgetMs@ (30000, the schema's default), and a program that outruns it
-- comes back as an ordinary reply of the form @{\"timeout\": {\"ms\": n}}@ —
-- an observation, not an error (@connection.md@ D13). The 60-second guard
-- therefore fires only when the process has stopped answering at all.
--
-- == Concurrency
--
-- One request is in flight at a time, enforced by an 'MVar'. The protocol is
-- a strictly alternating one and the pipe carries no request tags beyond the
-- id, so pipelining would buy nothing and risk interleaving two writers'
-- lines.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Agentic.Oracle
  ( -- * The connection
    Oracle,
    withOracle,

    -- * The requests
    oracleProgram,
    oracleString,
    oracleStringOf,
    oraclePing,

    -- * Failure
    OracleError (..),
    oracleErrorText,
  )
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception
  ( Exception,
    IOException,
    bracket,
    throwIO,
    try,
  )
import Control.Monad (unless, void)
import Data.Aeson
  ( Value (..),
    eitherDecodeStrict',
    encode,
    object,
    toJSON,
    (.=),
  )
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Pair)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import System.Directory (doesFileExist)
import System.IO
  ( BufferMode (..),
    Handle,
    hClose,
    hFlush,
    hSetBinaryMode,
    hSetBuffering,
  )
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    proc,
    terminateProcess,
    waitForProcess,
  )
import System.Timeout (timeout)

import Agentic.World (WorldSpec)

-- ---------------------------------------------------------------------------
-- The connection
-- ---------------------------------------------------------------------------

-- | A live oracle: its pipes, the next id to use, the mutex that keeps
-- requests from interleaving, and the error that killed it, if one has.
--
-- Opaque. Everything a caller can do with an oracle is one of the three
-- request functions.
data Oracle = Oracle
  { oracleTo :: !Handle,
    oracleFrom :: !Handle,
    oracleProcess :: !ProcessHandle,
    oracleNextId :: !(IORef Int),
    oracleLock :: !(MVar ()),
    -- | Set once, by the first transport failure. Every request after that
    -- one fails with the same error rather than reading a desynchronized
    -- stream (see the module header).
    oraclePoison :: !(IORef (Maybe OracleError))
  }

-- | How long to wait for one reply line before declaring the oracle wedged.
--
-- Twice the schema's default @budgetMs@, so that a program the oracle finds
-- expensive comes back as an in-band @{"timeout": …}@ reply — a recordable
-- asymmetry — and this guard is left to catch only a process that has stopped
-- answering.
readTimeoutMicros :: Int
readTimeoutMicros = 60 * 1000 * 1000

-- | The per-program budget sent with every program request, in milliseconds.
-- The schema's default, made explicit so the wire says what it means.
programBudgetMs :: Int
programBudgetMs = 30000

-- | Run an action with a freshly spawned oracle, shutting it down afterwards
-- however the action ends.
--
-- The binary's absence is checked before spawning, so a missing oracle is
-- 'OracleMissing' naming the path rather than an @exec@ failure from somewhere
-- inside @process@. Shutdown is the protocol's own: close stdin, let the
-- oracle see EOF and exit, and wait for it — with a few seconds' patience
-- before resorting to a signal, so that a normal run never terminates the
-- process it is talking to.
--
-- The child's stderr is inherited rather than captured: Lean panics and
-- @dbg_trace@ output belong in front of whoever is running the harness, and
-- capturing a stream nobody drains is a way to deadlock.
withOracle :: FilePath -> (Oracle -> IO a) -> IO a
withOracle path act = do
  there <- doesFileExist path
  unless there $ throwIO (OracleMissing path)
  bracket (startOracle path) stopOracle act

startOracle :: FilePath -> IO Oracle
startOracle path = do
  spawned <-
    createProcess
      (proc path [])
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = Inherit
        }
  case spawned of
    (Just hTo, Just hFrom, _, ph) -> do
      -- Bytes in, bytes out. The payload is UTF-8 either way; going through a
      -- 'Handle' encoder would put the process's locale between us and the
      -- oracle, and put newline translation between us and a protocol whose
      -- framing *is* the newline.
      mapM_
        (\h -> hSetBinaryMode h True >> hSetBuffering h (BlockBuffering Nothing))
        [hTo, hFrom]
      ids <- newIORef 1
      lock <- newMVar ()
      poison <- newIORef Nothing
      pure
        Oracle
          { oracleTo = hTo,
            oracleFrom = hFrom,
            oracleProcess = ph,
            oracleNextId = ids,
            oracleLock = lock,
            oraclePoison = poison
          }
    _ -> throwIO (OracleMissing path)

stopOracle :: Oracle -> IO ()
stopOracle o = do
  -- EOF on stdin is the documented clean shutdown; the close may itself fail
  -- if the oracle has already died, which is not worth reporting during
  -- teardown.
  ignoringIOErrors (hClose (oracleTo o))
  stopped <- timeout (5 * 1000 * 1000) (waitForProcess (oracleProcess o))
  case stopped of
    Just _ -> pure ()
    Nothing -> do
      terminateProcess (oracleProcess o)
      void (timeout (5 * 1000 * 1000) (waitForProcess (oracleProcess o)))
  ignoringIOErrors (hClose (oracleFrom o))

ignoringIOErrors :: IO () -> IO ()
ignoringIOErrors io = do
  r <- try io
  case r :: Either IOException () of
    Left _ -> pure ()
    Right () -> pure ()

-- ---------------------------------------------------------------------------
-- The requests
-- ---------------------------------------------------------------------------

-- | Observe a program under a list of worlds.
--
-- The program is passed as an already-encoded 'Value' — normally
-- @Agentic.Observe.printedValue@ for a built program, or @toJSON@ of a
-- generated 'Agentic.Raw.RawProgram' — because the two callers have different
-- things in hand and neither should have to build a fake one to ask a
-- question.
--
-- @worlds@ is always written to the wire, even when empty: the schema defaults
-- an /absent/ @worlds@ to @[{}]@, so omitting it for a program with no worlds
-- would silently get an echo world back and fail every comparison.
--
-- The reply is one of the schema's four shapes — @refused@, checked,
-- @{"timeout": …}@, or @{"error": …}@ — returned as it came, minus the @id@.
oracleProgram :: Oracle -> Value -> [WorldSpec] -> IO Value
oracleProgram o prog ws =
  request
    o
    [ "version" .= (3 :: Int),
      "program" .= prog,
      "worlds" .= toJSON ws,
      "budgetMs" .= programBudgetMs
    ]

-- | Ask one string-layer question: the operation, the answer code where the
-- operation takes one (@decode@ and @say@), and the input text.
--
-- The argument order is @Agentic.Text.stringOp@'s, because the two are meant
-- to be compared side by side and an argument swap between them would be a
-- silent one. The reply is @{"result": …}@, in the shape 'Agentic.Text.stringOp'
-- returns whole.
oracleString :: Oracle -> Text -> Maybe Text -> Text -> IO Value
oracleString o op mcode text =
  oracleStringOf o (["op" .= op] ++ code ++ ["text" .= text])
  where
    code = maybe [] (\c -> ["code" .= c]) mcode

-- | Ask one string-layer question written out in full: the fields of the
-- @{"string": …}@ object, whatever they are.
--
-- Wave three's ops carry fields the three original ones did not — @pattern@ for
-- @matchGlob@, @name@ for @fence@, @decider@ and @needles@ for @decide@ — and
-- the oracle dispatches off the whole object (@Conformance.stringOpOf@). So the
-- caller hands over the object, and the Haskell side computes its own answer
-- with @Agentic.Text.stringOpOf@ from the very same value: __one request, two
-- readings of it__, which is what makes a divergence a divergence rather than a
-- disagreement about what was asked.
oracleStringOf :: Oracle -> [Pair] -> IO Value
oracleStringOf o fields = request o ["string" .= object fields]

-- | Liveness: 'True' when the oracle answers @{"pong": true}@.
--
-- Worth doing once before a long run — a broken binary discovered on request
-- one is a clearer report than the same binary discovered on request 4000.
oraclePing :: Oracle -> IO Bool
oraclePing o = do
  reply <- request o ["ping" .= True]
  pure (lookupKey "pong" reply == Just (Bool True))

-- ---------------------------------------------------------------------------
-- One round trip
-- ---------------------------------------------------------------------------

-- | Send one request and read its reply, under the lock.
--
-- The id is allocated here, checked here, and stripped from the reply before
-- the caller ever sees it. Any failure poisons the connection.
request :: Oracle -> [Pair] -> IO Value
request o body = withMVar (oracleLock o) $ \() -> do
  readIORef (oraclePoison o) >>= mapM_ throwIO
  n <- atomicModifyIORef' (oracleNextId o) (\i -> (i + 1, i))
  let req = object (("id" .= n) : body)
  writeLine o n req
  readReply o n req

-- | Write one request as a single line, and flush — the oracle is reading
-- lines, and a request that sits in a buffer reads on the far side as an
-- oracle that has stopped answering.
writeLine :: Oracle -> Int -> Value -> IO ()
writeLine o n req = do
  written <- try (BL.hPut (oracleTo o) (encode req <> "\n") >> hFlush (oracleTo o))
  case written :: Either IOException () of
    -- A broken pipe here means the oracle exited before reading us; that is
    -- the same fact as an EOF on the read side, and says so.
    Left e -> die o (OracleClosed n req (tshow e))
    Right () -> pure ()

-- | Read one reply line, decode it, and check that it answers this request.
readReply :: Oracle -> Int -> Value -> IO Value
readReply o n req = do
  got <- timeout readTimeoutMicros (try (BC.hGetLine (oracleFrom o)))
  case got of
    Nothing -> die o (OracleTimeout n (readTimeoutMicros `div` 1000000) req)
    Just (Left e) -> die o (OracleClosed n req (tshow (e :: IOException)))
    Just (Right raw) ->
      -- The framing is the newline, which 'BC.hGetLine' has already taken;
      -- a carriage return would be left behind by an oracle writing CRLF.
      let line
            | not (BS.null raw), BC.last raw == '\r' = BS.init raw
            | otherwise = raw
       in case eitherDecodeStrict' line of
            Left err ->
              die o (OracleUnreadable n req (squash (T.pack err)) (utf8 line))
            Right reply
              | lookupKey "id" reply == Just (toJSON n) ->
                  pure (deleteKey "id" reply)
              | otherwise -> die o (OracleDesync n req reply)

-- | Record a transport failure as the connection's cause of death, and raise
-- it. Only the first is recorded: the ones after it are consequences.
die :: Oracle -> OracleError -> IO a
die o e = do
  already <- readIORef (oraclePoison o)
  case already of
    Nothing -> writeIORef (oraclePoison o) (Just e)
    Just _ -> pure ()
  throwIO e

-- ---------------------------------------------------------------------------
-- Failure
-- ---------------------------------------------------------------------------

-- | What can go wrong between here and the Lean side. None of these is a
-- conformance divergence — a divergence is a reply that arrived and was
-- wrong, and every one of these is a reply that did not arrive at all.
data OracleError
  = -- | No such binary. Naming the path, because the usual cause is a
    -- @.lake@ that was never built or was built somewhere else.
    OracleMissing FilePath
  | -- | No reply within the read timeout: the request id, the seconds
    -- waited, and the request itself.
    OracleTimeout Int Int Value
  | -- | The pipe closed, or the write failed: the request id, the request,
    -- and the underlying @IOException@.
    OracleClosed Int Value Text
  | -- | The reply line is not JSON: the request id, the request, the decoder's
    -- complaint, and the line as it arrived.
    OracleUnreadable Int Value Text Text
  | -- | The reply's @id@ is not the id sent: the two sides have lost their
    -- place in the stream. The request and the offending reply.
    OracleDesync Int Value Value
  deriving (Eq)

instance Show OracleError where
  show = T.unpack . oracleErrorText

instance Exception OracleError

-- | One line, naming the request id wherever there is one, so that a harness
-- can print the failure without unpacking the constructor.
oracleErrorText :: OracleError -> Text
oracleErrorText = \case
  OracleMissing path ->
    "oracle: no such binary: " <> T.pack path
  OracleTimeout n secs req ->
    "oracle: no reply to request "
      <> tshow n
      <> " within "
      <> tshow secs
      <> "s; the oracle is wedged. Request: "
      <> compact req
  OracleClosed n req err ->
    "oracle: the pipe closed on request "
      <> tshow n
      <> " ("
      <> squash err
      <> "). Request: "
      <> compact req
  OracleUnreadable n req err line ->
    "oracle: reply to request "
      <> tshow n
      <> " is not JSON ("
      <> err
      <> "): "
      <> clip line
      <> ". Request: "
      <> compact req
  OracleDesync n req reply ->
    "oracle: reply to request "
      <> tshow n
      <> " carries a different id; the stream is out of step. Request: "
      <> compact req
      <> " Reply: "
      <> compact reply

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

lookupKey :: Key -> Value -> Maybe Value
lookupKey k (Object o) = KM.lookup k o
lookupKey _ _ = Nothing

deleteKey :: Key -> Value -> Value
deleteKey k (Object o) = Object (KM.delete k o)
deleteKey _ v = v

utf8 :: BS.ByteString -> Text
utf8 = decodeUtf8With lenientDecode

compact :: Value -> Text
compact = clip . utf8 . BL.toStrict . encode

clip :: Text -> Text
clip t
  | T.length t > 400 = T.take 400 t <> "..."
  | otherwise = t

squash :: Text -> Text
squash = T.unwords . T.words

tshow :: (Show a) => a -> Text
tshow = T.pack . show
