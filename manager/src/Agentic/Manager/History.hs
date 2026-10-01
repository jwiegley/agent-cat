{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Bounded retained observations. Neither an opaque handle nor a native address owns a worker.
module Agentic.Manager.History
  ( LegacyHistory, bindLegacyHistory, LegacyRun (..), retainLegacyHandles, LegacyRoots, withLegacyRootsLoan, legacyRootIdentities,
    legacyWindow, legacyRun, withHistory, withHistoryResult, createHistoryLineage,
    retainView, verificationValue, managedRunInView ) where

import Agentic.Manager.Artifacts (withArtifactDownload)
import Agentic.Manager.Admission (Admission, ownsHistoryRun)
import Agentic.Manager.Authorization
import Agentic.Manager.Drafts (createLineageDraft)
import Agentic.Manager.Profile
import qualified Agentic.Manager.Protocol.Command as C
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.Store
import qualified Agentic.Manager.State as State
import Agentic.Runtime
import Control.Exception (IOException, SomeException, SomeAsyncException, fromException, bracket, try, throwIO)
import System.IO.Error (isDoesNotExistError)
import Control.Monad (forM, forM_, foldM, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..), object, (.=), toJSON, fromJSON, Result (..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Database.SQLite3 as SQL
import System.FilePath ((</>), takeFileName)
import System.Timeout (timeout)

-- | A local binding to one configured retention root and existing profile.
-- The constructor is private. Reload cannot rebind its retained root identity.
data LegacyHistory = LegacyHistory !FilePath !Text !Text

bindLegacyHistory :: CoordinationStore -> FilePath -> Text -> IO LegacyHistory
bindLegacyHistory store path profile = do
  result <- withStoreRetentionRoot store path profile $ \root -> do
    let identity = T.pack (privateRootIdentity root)
    revision <- fresh "history_binding_"
    runTransaction store $ do
      existing <- query "SELECT identity,profile_id,path FROM history_roots WHERE legacy=1 AND (identity=? OR path=?)" [text identity,text(T.pack path)]
      unless (null existing || existing == [[text identity,text profile,text(T.pack path)]]) (refuseTransaction C.StateConflict)
      if null existing then do
        execute "INSERT INTO history_roots VALUES (?,?,?,1)" [text identity,text profile,text(T.pack path)]
        pure ((),[Invalidation "service.changed" "/v1/capabilities" revision])
      else pure ((),[])
    pure (LegacyHistory path profile identity)
  either (const (throwIO C.ResourceUnavailable)) pure result

withLegacy :: CoordinationStore -> LegacyHistory -> (PrivateRoot -> IO a) -> IO a
withLegacy store (LegacyHistory path profile identity) action = do
  result <- withStoreRetentionRoot store path profile $ \root -> do
    unless (T.pack(privateRootIdentity root) == identity) (throwIO C.ResourceUnavailable)
    value <- action root
    assertPrivateRoot root
    pure value
  either (const (throwIO C.ResourceUnavailable)) pure result

-- | Complete materialization: at most 256 entries, 1MiB encoded, 30 seconds.
-- A larger or unbound catalogue refuses. No mutable offset or page token is returned.
-- WM025 owns consistent HTTP page sets over this bounded library observation.
withHistory :: CoordinationStore -> CredentialProof -> [LegacyHistory] -> Maybe Admission -> ([Value] -> IO ()) -> IO ()
withHistory store proof legacy admission respond = bounded $ do
  configured <- validateStoreHistoryBindings store [(path,profile) | LegacyHistory path profile _ <- legacy]
  either (const (throwIO C.ResourceUnavailable)) pure configured
  unless (length legacy <= 256 && Set.size(Set.fromList [identity | LegacyHistory _ _ identity <- legacy]) == length legacy) (throwIO C.InvalidRequest)
  managed <- withStoreFiles store $ \root -> do
    rows <- map (map (maybe SQL.SQLNull text)) <$> runRead store (do
      _ <- currentClient proof >>= either refuseTransaction pure
      values <- query "SELECT u.id,u.profile_id,u.root_identity,u.native_run_id,u.revision,u.supervision,r.workflow_id,u.request_id,u.parent_run_id,r.lineage_operation,u.result_artifact_id,u.result_state,a.verification_failure FROM runs u LEFT JOIN requests r ON r.id=u.request_id LEFT JOIN artifacts a ON a.id=u.result_artifact_id ORDER BY u.id LIMIT 257" []
      mapM (mapM (\value -> case value of SQL.SQLText t -> pure (Just t); SQL.SQLNull -> pure Nothing; _ -> refuseTransaction StoreIntegrity)) values)
    when (length rows > 256) (throwIO C.ViewTooLarge)
    bracket (try @IOException (openPrivateSubroot root ["runs"])) (either (const (pure ())) closePrivateRoot) $ \opened -> case opened of
      Left failure | isDoesNotExistError failure && null rows -> pure []
      Left _ -> throwIO C.ResourceUnavailable
      Right runs -> do
          now <- getCurrentTime
          let identity = T.pack(privateRootIdentity runs)
              addresses = [(native,row) | row@[_ ,_,SQL.SQLText bound,SQL.SQLText native,_,_,_,_,_,_,_,_,_] <- rows, bound == identity]
          unless (length addresses == length rows) (throwIO C.ResourceUnavailable)
          entries <- withPrivateDirectoryAt runs [] $ \fd -> foldRunCatalogueBoundedAt 256 (privateRootPath runs) fd Nothing now (\(size,seen,items) entry -> do
            let native = T.pack(takeFileName(entryDirectory entry))
            row <- maybe (throwIO C.ResourceUnavailable) pure (lookup native addresses)
            item <- renderManaged runs row entry
            (next,values) <- foldM appendItem (size,items) item
            pure (next,Set.insert native seen,values)) (2,Set.empty,[])
          let (size,seen,items) = entries
          (_,complete) <- foldM (\current (native,row) -> do
            rendered <- renderManaged runs row (CatalogueCorrupt (privateRootPath runs </> "runs" </> T.unpack native) "")
            foldM appendItem current rendered) (size,items) [(native,row) | (native,row) <- addresses,Set.notMember native seen]
          pure (reverse complete)
  observed <- legacyObserved store proof managed legacy
  items <- retainViews store observed
  when (length items > 256 || BS.length(C.encoded items) > 1048576) (throwIO C.ViewTooLarge)
  forM_ (Set.toList(Set.fromList [profile | Object fields <- items, Just(String profile) <- [KM.lookup "profileId" fields]])) $ \profile -> do
    allowed <- observable store proof profile
    unless allowed (throwIO C.Forbidden)
  respond items
  where
    renderManaged runs row entry = case row of
        [SQL.SQLText ident,SQL.SQLText profile,_,SQL.SQLText native,SQL.SQLText revision,SQL.SQLText supervision,workflow,request,parent,lineage,artifact,state,failure] -> do
          allowed <- observable store proof profile
          if not allowed then pure [] else do
            unless (T.pack(takeFileName(entryDirectory entry)) == native) (throwIO StoreIntegrity)
            owned <- case (admission,entry) of
              (Just controller,CatalogueRun record) -> ownsHistoryRun store controller ident (frontendRunId(recordManifest record)) (T.pack(privateRootIdentity runs))
              _ -> pure False
            let observed = case entry of CatalogueRun record | owned -> CatalogueRun record {recordOwnership=RunOwnedHere}; _ -> entry
                supervisionNow = if supervision == "owned" && not owned then "lost" else supervision
            result <- verification artifact state failure
            item <- renderEntry store runs profile ident revision (case workflow of SQL.SQLText value -> Just value; _ -> Nothing) (sqlValue request) (sqlValue parent) (sqlValue lineage) supervisionNow result observed
            pure [item]
        _ -> throwIO StoreIntegrity

-- | One legacy entry of a bound retention root in the frozen Run
-- representation, with its identifier and profile.
data LegacyRun = LegacyRun { legacyRunId :: !Text, legacyRunProfile :: !Text, legacyRunValue :: !Value }

-- | The most entry names that one retention pass lists in one bound root.
legacyNameBound :: Int
legacyNameBound = 65536

-- | The retention pass of the run collection. For each bound root of an
-- observable profile, it lists the entry names of the root, at most 65536,
-- without a manifest read, and retains an opaque handle for each name that
-- has none. One transaction inserts at most 100 handles, each with one
-- @run.changed@ invalidation. The result is the bindings of the observable
-- profiles, whose handles a run collection window can then select. A root
-- with more names refuses with @view-too-large@. Without a binding nothing is
-- read.
retainLegacyHandles :: CoordinationStore -> CredentialProof -> [LegacyHistory] -> IO [LegacyHistory]
retainLegacyHandles store proof legacy = bounded $ fmap concat $ forM legacy $ \binding@(LegacyHistory _ profile _) -> do
  allowed <- observable store proof profile
  if not allowed then pure [] else do
    withLegacy store binding $ \root -> do
      names <- listPrivateDirectoryAt root ["runs"] (legacyNameBound + 1)
      when (length names > legacyNameBound) (throwIO C.ViewTooLarge)
      _ <- retainHandles store root profile (map T.pack names)
      pure ()
    pure [binding]

-- | The bound roots that one collection source opened under its file slot.
newtype LegacyRoots = LegacyRoots [(LegacyHistory,PrivateRoot)]

-- | The identity and profile of each opened root.
legacyRootIdentities :: LegacyRoots -> [(Text,Text)]
legacyRootIdentities (LegacyRoots roots) = [(identity,profile) | (LegacyHistory _ profile identity,_) <- roots]

-- | The file slot of one collection source and the bound roots under it. The
-- release closes the roots and returns the slot. A root that the
-- configuration no longer binds, or whose identity changed, refuses as an
-- unknown run.
withLegacyRootsLoan :: CoordinationStore -> [LegacyHistory] -> (IO () -> PrivateRoot -> LegacyRoots -> IO a) -> IO a
withLegacyRootsLoan store legacy action = do
  result <- withStoreRetentionRootsLoan store [(path,profile) | LegacyHistory path profile _ <- legacy] $ \release root opened -> do
    forM_ (zip legacy opened) $ \(LegacyHistory _ _ identity,retained) ->
      unless (T.pack(privateRootIdentity retained) == identity) (throwIO C.ResourceUnavailable)
    action release root (LegacyRoots (zip legacy opened))
  either (const (throwIO C.ResourceUnavailable)) pure result

-- | The legacy entries of one run collection window, in the order of the
-- given identifiers, which are history handles of the opened roots. The
-- window decodes at most the first 256 entries, each by its component name,
-- and keeps the longest prefix of at most 1 MiB encoded. It retains the
-- parent handles, result references and revisions of the decoded entries
-- before it returns. The second result is the first identifier that the
-- window does not hold, when it does not hold them all. A first entry above
-- 1 MiB refuses with @view-too-large@.
legacyWindow :: CoordinationStore -> LegacyRoots -> [(Text,FrontendInvocation)] -> [Text] -> IO ([LegacyRun],Maybe Text)
legacyWindow _ _ _ [] = pure ([],Nothing)
legacyWindow store (LegacyRoots roots) invocations idents = do
  let decodable = take 256 idents
  rows <- runRead store $ do
    found <- query "SELECT id,root_identity,profile_id,component FROM history_entries WHERE id IN (SELECT value FROM json_each(?))"
      [jsonText decodable]
    mapM (\row -> case row of
      [SQL.SQLText ident,SQL.SQLText identity,SQL.SQLText profile,SQL.SQLText component] -> pure (ident,(identity,profile,component))
      _ -> refuseTransaction StoreIntegrity) found
  let addresses = Map.fromList rows
  ordered <- forM decodable $ \ident -> case Map.lookup ident addresses of
    Just (identity,profile,component) -> pure (ident,identity,profile,component)
    Nothing -> refuseBusy "history-address" Nothing
  decoded <- observeLegacy store roots (pure invocations) ordered >>= retainViews store . map snd
  runs <- mapM legacyRunOf decoded
  let fit _ [] = ([],Nothing)
      fit size (entry:rest)
        | next > 1048576 = ([],Just (legacyRunId entry))
        | otherwise = let (held,limit) = fit next rest in (entry:held,limit)
        where next = size + BS.length (C.encoded (legacyRunValue entry)) + 1
      (kept,stop) = fit (2 :: Int) runs
  when (null kept) (throwIO C.ViewTooLarge)
  pure (kept,maybe (listToMaybe (drop 256 idents)) Just stop)

-- | The legacy entry with this identifier. The result is 'Nothing' when no
-- retained legacy entry has the identifier, so the caller reads a managed
-- run. A retained entry of a root that this service does not bind, or of a
-- profile that the credential cannot observe, refuses as an unknown run.
-- The read decodes only this entry, by the component name of its handle.
legacyRun :: CoordinationStore -> CredentialProof -> [LegacyHistory] -> Text -> IO (Maybe LegacyRun)
legacyRun _ _ [] _ = pure Nothing
legacyRun store proof legacy ident = do
  addresses <- runRead store $ do
    _ <- currentClient proof >>= either refuseTransaction pure
    unless (C.validId ident) (refuseTransaction C.InvalidRequest)
    rows <- query "SELECT root_identity,profile_id,component FROM history_entries WHERE id=?" [text ident]
    mapM (\row -> case row of
      [SQL.SQLText identity,SQL.SQLText profile,SQL.SQLText component] -> pure (identity,profile,component)
      _ -> refuseTransaction StoreIntegrity) rows
  case addresses of
    [] -> pure Nothing
    [(identity,profile,component)] -> bounded $ do
      binding <- case [binding | binding@(LegacyHistory _ _ bound) <- legacy, bound == identity] of
        [binding] -> pure binding
        _ -> throwIO C.ResourceUnavailable
      allowed <- observable store proof profile
      unless allowed (throwIO C.ResourceUnavailable)
      withLegacy store binding $ \root -> do
        observed <- observeLegacy store [(binding,root)] (configuredInvocations store) [(ident,identity,profile,component)]
        retained <- retainViews store (map snd observed)
        case retained of
          [value] -> Just <$> legacyRunOf value
          _ -> throwIO StoreIntegrity
    _ -> throwIO StoreIntegrity

legacyRunOf :: Value -> IO LegacyRun
legacyRunOf item = case item of
  Object fields | Just (String ident) <- KM.lookup "id" fields, Just (String profile) <- KM.lookup "profileId" fields ->
    pure (LegacyRun ident profile item)
  _ -> throwIO StoreIntegrity

-- The legacy entries of each binding after the given items, within the shared
-- bounds of one history observation.
legacyObserved :: CoordinationStore -> CredentialProof -> [Value] -> [LegacyHistory] -> IO [Value]
legacyObserved store proof = foldM (\items binding -> do
  values <- legacyItems store proof (256-length items) binding
  let combined = items <> values
  when (BS.length(C.encoded combined) > 1048576) (throwIO C.ViewTooLarge)
  pure combined)

-- The complete legacy observation of one binding: every entry of the root in
-- name order, then each parent that the root does not hold, within the limit.
legacyItems :: CoordinationStore -> CredentialProof -> Int -> LegacyHistory -> IO [Value]
legacyItems store proof limit binding@(LegacyHistory _ profile identity) = do
  allowed <- observable store proof profile
  if not allowed then pure [] else withLegacy store binding $ \root -> do
    names <- Set.toAscList . Set.fromList . map T.pack <$> listPrivateDirectoryAt root ["runs"] limit
    handles <- retainHandles store root profile names
    entries <- observeLegacy store [(binding,root)] (configuredInvocations store)
      [(handle,identity,profile,name) | name <- names, Just handle <- [Map.lookup name handles]]
    let present = Set.fromList names
        missing = Set.toAscList (Set.fromList [(name,handle) | (parents,_) <- entries, (name,handle) <- parents, Set.notMember name present])
    when (length entries + length missing > limit) (throwIO C.ViewTooLarge)
    parents <- observeLegacy store [(binding,root)] (configuredInvocations store)
      [(handle,identity,profile,name) | (name,handle) <- missing]
    (_,complete) <- foldM appendItem (2,[]) (map snd (entries <> parents))
    pure (reverse complete)

-- One observation of the entry with this component name, as the run
-- catalogue observes it. A directory that cannot be read is corrupt.
observeEntry :: PrivateRoot -> UTCTime -> Text -> IO CatalogueEntry
observeEntry root now name = do
  let directory = privateRootPath root </> "runs" </> T.unpack name
  outcome <- try @SomeException $ withPrivateDirectoryAt root ["runs",T.unpack name] $ \descriptor ->
    fst <$> readRunRecordWithEnvelopesAt directory descriptor Nothing now
  case outcome of
    Right record -> pure (CatalogueRun record)
    Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
    Left _ -> pure (CatalogueCorrupt directory "")

-- The legacy entries at these addresses (handle, root identity, profile and
-- component), each decoded by its component name and rendered with its
-- handle as the revision. Each result carries the parent component and
-- handle that its manifest names. The parent handles and the result
-- references are retained in batches first. The address profile must be the
-- profile of its bound root.
observeLegacy :: CoordinationStore -> [(LegacyHistory,PrivateRoot)] -> IO [(Text,FrontendInvocation)]
  -> [(Text,Text,Text,Text)] -> IO [([(Text,Text)],Value)]
observeLegacy store roots configuration addresses = do
  now <- getCurrentTime
  observed <- forM addresses $ \(ident,identity,profile,component) -> do
    root <- case [root | (LegacyHistory _ bound rootIdentity,root) <- roots, rootIdentity == identity, bound == profile] of
      [root] -> pure root
      _ -> throwIO C.ResourceUnavailable
    entry <- observeEntry root now component
    manifest <- entryManifest root entry
    pure (ident,identity,profile,root,entry,manifest)
  parentHandles <- fmap Map.unions $ forM roots $ \(LegacyHistory _ profile identity,root) -> do
    let parents = [runIdText parent | (_,rootIdentity,_,_,_,manifest) <- observed, rootIdentity == identity,
          Just parent <- [manifest >>= frontendParentRunId]]
    handles <- if null parents then pure Map.empty else retainHandles store root profile parents
    pure (Map.mapKeys (\name -> (identity,name)) handles)
  references <- retainResults store [(ident,case entry of CatalogueRun record -> recordSnapshot record >>= snapshotResult; _ -> Nothing)
    | (ident,_,_,_,entry,_) <- observed]
  values <- forM observed $ \(ident,identity,profile,root,entry,manifest) -> do
    let parent = do
          name <- runIdText <$> (manifest >>= frontendParentRunId)
          handle <- Map.lookup (identity,name) parentHandles
          pure (name,handle)
        result = case Map.lookup ident references of
          Nothing -> object ["state" .= ("absent"::Text)]
          Just _ -> object ["state" .= ("referenced"::Text),"artifactId" .= resultHandle ident]
    item <- renderEntryWith configuration root profile ident ident Nothing Null (toJSON (fmap snd parent))
      (toJSON (manifest >>= frontendLineage)) "observer" result entry
    pure (maybe [] pure parent,item)
  forM_ roots (assertPrivateRoot . snd)
  pure values

appendItem :: (Int,[Value]) -> Value -> IO (Int,[Value])
appendItem (size,items) item = do
  let next = size + BS.length(C.encoded item) + 1
  when (next > 1048576 || length items >= 256) (throwIO C.ViewTooLarge)
  pure (next,item:items)

entryManifest :: PrivateRoot -> CatalogueEntry -> IO (Maybe FrontendManifest)
entryManifest _ (CatalogueRun record) = pure (Just(recordManifest record))
entryManifest root (CatalogueCorrupt directory _) = do
  attempt <- try @IOException $ withPrivateDirectoryAt root ["runs",takeFileName directory] readFrontendManifestAt
  pure $ case attempt of Right value | runIdText(frontendRunId value) == T.pack(takeFileName directory) -> Just value; _ -> Nothing

retainView :: CoordinationStore -> Value -> IO Value
retainView store item = do
  retained <- retainViews store [item]
  case retained of
    [value] -> pure value
    _ -> throwIO StoreIntegrity

-- | Retain the revision of each observed view, in transactions of at most
-- 100 views. An unchanged view keeps its retained revision, and a changed or
-- new view receives a fresh revision with one @run.changed@ invalidation. A
-- managed view whose sampled revision is no longer current refuses.
retainViews :: CoordinationStore -> [Value] -> IO [Value]
retainViews store items = concat <$> mapM retainChunk (chunks 100 items)
  where
    retainChunk chunk = do
      sampled <- forM chunk $ \item -> case item of
        Object fields | Just (String ident) <- KM.lookup "id" fields -> do
          revision <- fresh "history_revision_"
          let digest = T.pack(show(hash(C.encoded(Object(KM.delete "revision" fields)))::Digest SHA256))
          pure (ident,fields,digest,revision)
        _ -> throwIO StoreIntegrity
      let idents = [ident | (ident,_,_,_) <- sampled]
      actual <- runTransaction store $ do
        currentRows <- query "SELECT id,revision FROM runs WHERE id IN (SELECT value FROM json_each(?))" [jsonText idents]
        viewRows <- query "SELECT id,revision,digest FROM history_views WHERE id IN (SELECT value FROM json_each(?))" [jsonText idents]
        currents <- Map.fromList <$> mapM (\row -> case row of
          [SQL.SQLText ident,SQL.SQLText revision] -> pure (ident,revision)
          _ -> refuseTransaction StoreIntegrity) currentRows
        views <- Map.fromList <$> mapM (\row -> case row of
          [SQL.SQLText ident,SQL.SQLText revision,SQL.SQLText digest] -> pure (ident,(revision,digest))
          _ -> refuseTransaction StoreIntegrity) viewRows
        results <- forM sampled $ \(ident,fields,digest,revision) -> do
          let current = Map.lookup ident currents
          unless (maybe True (\value -> KM.lookup "revision" fields == Just (String value)) current) (refuseBusyTransaction "history-revision")
          case Map.lookup ident views of
            Just (retained,previous) | previous == digest -> do
              let revisionNow = fromMaybe retained current
              when (revisionNow /= retained) (execute "UPDATE history_views SET revision=? WHERE id=?" [text revisionNow,text ident])
              pure (revisionNow,[Invalidation "run.changed" (uri ident) revisionNow | revisionNow /= retained])
            _ -> do
              execute "INSERT INTO history_views VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,digest=excluded.digest" [text ident,text revision,text digest]
              forM_ current $ \_ -> execute "UPDATE runs SET revision=? WHERE id=?" [text revision,text ident]
              pure (revision,[Invalidation "run.changed" (uri ident) revision])
        pure (map fst results,concatMap snd results)
      pure [Object(KM.insert "revision" (String revision) fields) | ((_,fields,_,_),revision) <- zip sampled actual]

observable :: CoordinationStore -> CredentialProof -> Text -> IO Bool
observable store proof profile = do
  configured <- withStoreConfiguration store $ \_ profiles -> pure (profile `elem` map publicId profiles)
  current <- either (const (throwIO C.StorageUnavailable)) pure configured
  allowed <- runRead store (authorizeProfile proof profile [C.Observe])
  pure (current && either (const False) (const True) allowed)

entryDirectory :: CatalogueEntry -> FilePath
entryDirectory (CatalogueRun record) = recordDirectory record
entryDirectory (CatalogueCorrupt directory _) = directory

-- The opaque handle of each component name of the root. The names are read
-- in groups of at most 500, and the missing handles are inserted in
-- transactions of at most 100, each with one @run.changed@ invalidation. A
-- handle of the same component under another profile is an integrity fault.
retainHandles :: CoordinationStore -> PrivateRoot -> Text -> [Text] -> IO (Map.Map Text Text)
retainHandles store root profile components = do
  let identity = T.pack(privateRootIdentity root)
      names = Set.toAscList (Set.fromList components)
      existing group = do
        rows <- query "SELECT component,id,profile_id FROM history_entries WHERE root_identity=? AND component IN (SELECT value FROM json_each(?))"
          [text identity,jsonText group]
        Map.fromList <$> mapM (\row -> case row of
          [SQL.SQLText component,SQL.SQLText ident,SQL.SQLText bound] | bound == profile -> pure (component,ident)
          _ -> refuseTransaction StoreIntegrity) rows
  found <- Map.unions <$> mapM (runRead store . existing) (chunks 500 names)
  inserted <- forM (chunks 100 [name | name <- names, Map.notMember name found]) $ \group -> do
    fresh' <- forM group $ \name -> (,) name <$> fresh "history_"
    runTransaction store $ do
      current <- existing group
      added <- forM [(name,ident) | (name,ident) <- fresh', Map.notMember name current] $ \(name,ident) -> do
        execute "INSERT INTO history_entries(id,root_identity,profile_id,component) VALUES (?,?,?,?)" [text ident,text identity,text profile,text name]
        pure (name,ident)
      pure (Map.union current (Map.fromList added),[Invalidation "run.changed" (uri ident) ident | (_,ident) <- added])
  pure (Map.unions (found:inserted))

renderEntry :: CoordinationStore -> PrivateRoot -> Text -> Text -> Text -> Maybe Text -> Value -> Value -> Value -> Text -> Value -> CatalogueEntry -> IO Value
renderEntry store = renderEntryWith (storeInvocations store >>= either (const (throwIO C.StorageUnavailable)) pure)

renderEntryWith :: IO [(Text,FrontendInvocation)] -> PrivateRoot -> Text -> Text -> Text -> Maybe Text -> Value -> Value -> Value -> Text -> Value -> CatalogueEntry -> IO Value
renderEntryWith configuration root profile ident revision workflow request parent lineage supervision result entry = do
  manifest <- entryManifest root entry
  case manifest of
    Nothing -> pure (object ["version" .= (1::Int),"kind" .= ("unreadable-manifest"::Text),"id" .= ident,"revision" .= revision,
      "profileId" .= profile,"category" .= ("manifest-unavailable"::Text),"links" .= object ["self" .= uri ident]])
    Just value -> do
      configured <- configuration
      let current = lookup profile configured
      let expectedWorkflow = workflowIdentity profile (frontendWorkflow value)
      unless (maybe True (==expectedWorkflow) workflow) (throwIO C.ResourceUnavailable)
      let workflowId = expectedWorkflow
      let compatibility = if frontendVersion value == 1 then object ["kind" .= ("legacy"::Text)] else object ["kind" .= ("versioned"::Text),"frontendManifestVersion" .= frontendVersion value]
          (snapshot,foreignOwner,corrupt) = case entry of CatalogueRun record -> (recordSnapshot record,recordOwnership record == RunOwnedElsewhere,False); _ -> (Nothing,False,True)
          runtime = do
            s <- snapshot
            envelope <- snapshotLastEnvelope s
            case runSnapshotValue s of
              Object fields -> Just (Object (KM.insert "protocolVersion" (toJSON(envelopeVersion envelope)) (KM.filterWithKey (\k _ -> k `elem` ["status","lastSequence"]) fields)))
              _ -> Nothing
          limitations = ["legacy" | frontendVersion value == 1] <> ["foreign-owner" | foreignOwner] <> ["corrupt-journal" | corrupt]
            <> ["incompatible-invocation" | maybe False (\invocation -> either (const True) (const False) (retainLineageInvocation value (Just invocation))) current]
            <> ["lost-supervision" | supervision == "lost"] <> ["quarantined" | supervision == "cleanup-pending"]
      pure (object ["version" .= (1::Int),"id" .= ident,"revision" .= revision,"profileId" .= profile,"workflowId" .= workflowId,
        "requestId" .= request,"parentRunId" .= parent,"lineage" .= lineage,"manifest" .= compatibility,"runtime" .= runtime,
        "supervision" .= supervision,"integrity" .= (if corrupt then "corrupt" else "valid"::Text),"verification" .= result,"limitations" .= (limitations::[Text]),
        "links" .= object ["self" .= uri ident,"snapshot" .= (uri ident<>"/snapshot"),"control" .= (uri ident<>"/control"),"outputs" .= (uri ident<>"/outputs"),"exports" .= (uri ident<>"/exports"),"lineageRequests" .= (uri ident<>"/lineage-requests")]])

-- | One managed observation under an existing response loan. Runtime summaries
-- use the manager's immutable ingested prefix, not a later native file suffix.
managedRunInView :: CoordinationStore -> PrivateRoot -> CredentialProof -> AuthorizedView -> Maybe Admission
  -> [(Text,FrontendInvocation)] -> Text -> IO Value
managedRunInView store retainedRoot proof view admission invocations ident = do
  revalidateAuthorizedView view >>= either throwIO pure
  (fields,cut) <- runRead store $ do
    _ <- currentClient proof >>= either refuseTransaction pure
    unless (C.validId ident) (refuseTransaction C.InvalidRequest)
    rows <- query "SELECT u.id,u.profile_id,u.root_identity,u.native_run_id,u.revision,u.supervision,r.workflow_id,u.request_id,u.parent_run_id,r.lineage_operation,u.result_artifact_id,u.result_state,a.verification_failure FROM runs u LEFT JOIN requests r ON r.id=u.request_id LEFT JOIN artifacts a ON a.id=u.result_artifact_id WHERE u.id=? AND EXISTS(SELECT 1 FROM credential_scopes s WHERE s.credential_id=? AND s.profile_id=u.profile_id AND s.scope='observe')" [text ident,text (credentialRateKey proof)]
    row <- case rows of [row] -> pure row; _ -> refuseTransaction C.ResourceUnavailable
    case row of
      SQL.SQLText actual:SQL.SQLText profile:SQL.SQLText root:SQL.SQLText native:_ -> do
        unless (actual == ident && profile `elem` map fst invocations) (refuseTransaction C.Forbidden)
        nativeId <- either (const (refuseTransaction StoreIntegrity)) pure (mkRunId native)
        prefix <- State.captureProjectionCut (State.RunAssociation ident profile root nativeId)
        values <- mapM (\value -> case value of SQL.SQLText t -> pure (Just t); SQL.SQLNull -> pure Nothing; _ -> refuseTransaction StoreIntegrity) row
        pure (values,prefix)
      _ -> refuseTransaction StoreIntegrity
  snapshot <- fmap checkpointSnapshot <$> State.restoreProjectionCut store cut
  case map (maybe SQL.SQLNull text) fields of
    [_,SQL.SQLText profile,SQL.SQLText identity,SQL.SQLText native,SQL.SQLText revision,SQL.SQLText supervision,workflow,request,parent,lineage,artifact,state,failure] ->
      bracket (openPrivateSubroot retainedRoot ["runs"]) closePrivateRoot $ \runs -> do
        unless (T.pack (privateRootIdentity runs) == identity) (throwIO C.ResourceUnavailable)
        now <- getCurrentTime
        let directory = privateRootPath runs </> "runs" </> T.unpack native
        observed <- try @SomeException $ withPrivateDirectoryAt runs ["runs",T.unpack native] $ \descriptor ->
          fst <$> readRunRecordWithEnvelopesAt directory descriptor Nothing now
        owned <- case (admission,observed) of
          (Just controller,Right record) -> ownsHistoryRun store controller ident (frontendRunId (recordManifest record)) identity
          _ -> pure False
        entry <- case observed of
          Right record -> pure (CatalogueRun record {recordSnapshot = snapshot,
            recordOwnership = if owned then RunOwnedHere else recordOwnership record})
          Left exception | Just _ <- (fromException exception :: Maybe SomeAsyncException) -> throwIO exception
          Left _ -> pure (CatalogueCorrupt directory "")
        result <- verification artifact state failure
        value <- renderEntryWith (pure invocations) runs profile ident revision
          (case workflow of SQL.SQLText item -> Just item; _ -> Nothing)
          (sqlValue request) (sqlValue parent) (sqlValue lineage)
          (if supervision == "owned" && not owned then "lost" else supervision) result entry
        revalidateAuthorizedView view >>= either throwIO pure
        pure value
    _ -> throwIO StoreIntegrity

verification :: SQL.SQLData -> SQL.SQLData -> SQL.SQLData -> IO Value
verification artifact state reason = either throwIO pure (verificationValue artifact state reason)

-- | Public verification facts from the existing durable result association.
verificationValue :: SQL.SQLData -> SQL.SQLData -> SQL.SQLData -> Either StoreFailure Value
verificationValue (SQL.SQLText artifact) (SQL.SQLText state) _ | state `elem` ["referenced","verified"] = Right (object ["state" .= state,"artifactId" .= artifact])
verificationValue (SQL.SQLText artifact) (SQL.SQLText "unavailable") (SQL.SQLText reason) = Right (object ["state" .= ("unavailable"::Text),"artifactId" .= artifact,"reason" .= reason])
verificationValue SQL.SQLNull (SQL.SQLText "absent") _ = Right (object ["state" .= ("absent"::Text)])
verificationValue _ _ _ = Left StoreIntegrity

-- The retained result reference of each entry. An entry without a retained
-- reference retains the observed one, in transactions of at most 100, each
-- with one @artifact.changed@ invalidation. An observed reference that
-- differs from the retained one refuses as unavailable.
retainResults :: CoordinationStore -> [(Text,Maybe ResultRef)] -> IO (Map.Map Text ResultRef)
retainResults store observed = do
  let retainedIn group = do
        rows <- query "SELECT entry_id,reference FROM history_results WHERE entry_id IN (SELECT value FROM json_each(?))" [jsonText group]
        Map.fromList <$> mapM (\row -> case row of
          [SQL.SQLText ident,SQL.SQLBlob bytes] -> pure (ident,bytes)
          _ -> refuseTransaction StoreIntegrity) rows
      observedBytes = Map.fromList [(ident,C.encoded reference) | (ident,Just reference) <- observed]
  found <- Map.unions <$> mapM (runRead store . retainedIn) (chunks 100 (map fst observed))
  inserted <- forM (chunks 100 [(ident,bytes) | (ident,bytes) <- Map.toList observedBytes, Map.notMember ident found]) $ \group ->
    runTransaction store $ do
      current <- retainedIn (map fst group)
      added <- forM [(ident,bytes) | (ident,bytes) <- group, Map.notMember ident current] $ \(ident,bytes) -> do
        execute "INSERT INTO history_results VALUES (?,?)" [text ident,SQL.SQLBlob bytes]
        pure (ident,bytes)
      pure (Map.union current (Map.fromList added),
        [Invalidation "artifact.changed" ("/v1/artifacts/"<>resultHandle ident) (resultHandle ident) | (ident,_) <- added])
  let retained = Map.unions (found:inserted)
  forM_ (Map.toList retained) $ \(ident,bytes) ->
    unless (maybe True (==bytes) (Map.lookup ident observedBytes)) (throwIO C.ResourceUnavailable)
  traverse (\bytes -> do
    value <- either (const (throwIO StoreIntegrity)) pure (decodeStrictValue bytes)
    case fromJSON value of Success reference -> pure reference; Error _ -> throwIO StoreIntegrity) retained

-- | Verified retained result through the shared Artifacts/Runtime owner. Legacy roots never mutate.
withHistoryResult :: CoordinationStore -> CredentialProof -> [LegacyHistory] -> Text -> (AuthorizedView -> BS.ByteString -> IO ()) -> IO ()
withHistoryResult store proof bindings ident respond = bounded $ do
  (profile,identity) <- runRead store $ do
    rows <- query "SELECT profile_id,root_identity FROM history_entries WHERE id=?" [text ident]
    case rows of
      [[SQL.SQLText profile,SQL.SQLText identity]] -> do
        _ <- authorizeProfile proof profile [C.Observe] >>= either refuseTransaction pure
        pure (profile,identity)
      _ -> refuseTransaction C.ResourceUnavailable
  unless (length [() | LegacyHistory _ p r <- bindings,p==profile,r==identity] == 1) (throwIO C.ResourceUnavailable)
  withArtifactDownload store proof (resultHandle ident) (\view _ bytes -> respond view bytes)

-- | Observation handles are not admitted as parents. No command or worker effect precedes refusal.
createHistoryLineage :: CoordinationStore -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString -> IO (Either C.CommandFailure C.CommandReceipt)
createHistoryLineage store proof ident key version body = do
  outcome <- try @C.CommandFailure $ runRead store $ do
    _ <- currentClient proof >>= either refuseTransaction pure
    rows <- query "SELECT profile_id FROM history_entries WHERE id=?" [text ident]
    case rows of
      [[SQL.SQLText profile]] -> do
        _ <- authorizeProfile proof profile [C.Observe,C.Submit] >>= either refuseTransaction pure
        pure True
      [] -> pure False
      _ -> refuseTransaction StoreIntegrity
  case outcome of
    Left failure -> pure (Left failure)
    Right True -> pure (Left C.OwnershipUnavailable)
    Right False -> createLineageDraft store proof ident key version body

bounded :: IO a -> IO a
bounded action = do
  outcome <- try @SomeException (timeout 30000000 action >>= maybe (throwIO C.ViewTooLarge) pure)
  case outcome of
    Right value -> pure value
    Left failure
      | Just _ <- fromException @IOException failure -> throwIO C.ResourceUnavailable
      | Just _ <- fromException @StoreError failure -> throwIO C.ResourceUnavailable
      | otherwise -> throwIO failure
chunks :: Int -> [a] -> [[a]]
chunks _ [] = []
chunks size values = let (group,rest) = splitAt size values in group : chunks size rest
jsonText :: [Text] -> SQL.SQLData
jsonText = SQL.SQLText . TE.decodeUtf8 . C.encoded
configuredInvocations :: CoordinationStore -> IO [(Text,FrontendInvocation)]
configuredInvocations store = storeInvocations store >>= either (const (throwIO C.StorageUnavailable)) pure
fresh :: Text -> IO Text
fresh prefix = do bytes <- getRandomBytes 24 :: IO BS.ByteString; pure (prefix<>T.pack(show(hash bytes::Digest SHA256)))
text :: Text -> SQL.SQLData
text = SQL.SQLText
sqlValue :: SQL.SQLData -> Value
sqlValue (SQL.SQLText value) = String value
sqlValue _ = Null
uri :: Text -> Text
uri ident = "/v1/runs/"<>ident
resultHandle :: Text -> Text
resultHandle ident = "artifact_"<>ident
