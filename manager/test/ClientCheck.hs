{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import qualified Agentic.Manager.Client as C
import Control.Concurrent.Async (AsyncCancelled, async, cancel, waitCatch)
import Control.Exception (bracket, fromException)
import Control.Monad (unless, void)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hSetBuffering, stdout, BufferMode (LineBuffering))

check :: String -> Bool -> IO ()
check label value = unless value (die ("FAIL " <> label)) >> putStrLn ("PASS " <> label)

right :: Show e => Either e a -> IO a
right = either (die . show) pure

field :: Text -> Value -> Value
field key (Object fields) = maybe Null id (KM.lookup (Key.fromText key) fields)
field _ _ = Null

string :: Value -> Text
string (String value) = value
string _ = error "expected public string"

withClient :: FilePath -> (C.Client -> IO a) -> IO a
withClient path = bracket (C.connectClientProfile path >>= right) C.closeClient

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  arguments <- getArgs
  case arguments of
    ["real",profile] -> withClient profile $ \client -> do
      profilesURI <- right (C.reference client "/v1/profiles")
      profiles <- C.getPageSet client profilesURI >>= right
      check "public client assembles profile page" (length (C.pageSetItems profiles) == 1)
      selected <- case C.pageSetItems profiles of
        [profileValue] -> pure (string (field "id" profileValue))
        _ -> die "expected one profile"
      workflowsURI <- right (C.reference client ("/v1/workflows?profileId=" <> selected))
      workflows <- C.getPageSet client workflowsURI >>= right
      check "public client assembles actual workflow catalogue" (not (null (C.pageSetItems workflows)))
      snapshotURI <- right (C.reference client "/v1/snapshot")
      snapshot <- C.getPageSet client snapshotURI >>= right
      let cursor = string (field "cursor" (C.pageSetMetadata snapshot))
      events <- C.pollEvents client cursor >>= right
      check "public client sends Last-Event-ID polling" (C.responseStatus events == 200)
      observed <- C.observeResource client workflowsURI >>= right
      check "GET observation retains exact resource URI" (C.referenceURI (C.observedReference observed) == C.referenceURI workflowsURI)
      withClient profile $ \other -> do
        wrong <- C.prepareObserved other observed (object ["operation" .= ("enqueue" :: Text)])
        check "GET observation cannot migrate to another session" (case wrong of Left C.WrongEndpoint -> True; _ -> False)
      C.closeClient client
      closed <- C.getResource client profilesURI
      check "closed client rejects later reads" (case closed of Left C.ClientClosed -> True; _ -> False)
    ["pages",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/snapshot")
      pages <- C.getPageSet client uri >>= right
      check "complete multi-page assembly preserves every item" (C.pageSetItems pages == [String "first",String "second"])
    ["bad-pages",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/snapshot")
      result <- C.getPageSet client uri
      check "mismatched page set refuses rather than installs partial data" (case result of Left C.InvalidResponse -> True; _ -> False)
    ["nonce",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/requests/request_probe")
      observed <- C.observeResource client uri >>= right
      pending <- C.prepareObserved client observed (object ["operation" .= ("enqueue" :: Text)]) >>= right
      result <- C.sendCommand client pending
      check "maximum authority epoch reaches explicit single HTTP attempt" (case result of Left (C.Refused 409 "state-conflict") -> True; _ -> False)
    ["lost",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/requests")
      pending <- C.prepareCommand client uri Nothing (object ["probe" .= True]) >>= right
      result <- C.sendCommand client pending
      check "lost reply remains an explicit failure without retry" (case result of Left C.TransportUnavailable -> True; _ -> False)
    ["changed",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/profiles")
      result <- C.getResource client uri
      check "credential change before response installation refuses old session" (case result of Left C.CredentialChanged -> True; _ -> False)
    ["cancel",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/blocked")
      original <- async (C.getResource client uri)
      line <- getLine
      unless (line == "cancel") (die "unexpected cancellation barrier")
      cancel original
      outcome <- waitCatch original
      check "original HTTP task is cancelled and joined" (case outcome of
        Left failure -> case fromException failure :: Maybe AsyncCancelled of Just _ -> True; _ -> False
        Right _ -> False)
    ["failure",profile,kind] -> do
      result <- C.connectClientProfile profile
      check "fixed client-profile refusal" $ case result of
        Left C.ClientFileUnavailable -> kind == "file"
        Left C.InvalidClientProfile -> kind == "profile"
        Left C.TransportUnavailable -> kind == "transport"
        Left C.UnsupportedVersion -> kind == "version"
        Left C.RedirectRefused -> kind == "redirect"
        _ -> False
      either (const (pure ())) (void . C.closeClient) result
    _ -> die "usage: manager-client-check MODE ABS_CLIENT_PROFILE [FAILURE_KIND]"
