{-# LANGUAGE OverloadedStrings #-}

-- | The manager-log records of the mutating local administration operations:
-- the command record that the admission transaction appends before COMMIT,
-- and the receipt that follows the COMMIT. Credential administration and
-- quarantine release use them.
module Agentic.Manager.Administration
  ( Logged, localAdministrator, recordAdministration, recordAdministrationReceipt
  ) where

import Agentic.Manager.Flow
  (AdministrationBody, FlowRecordClass (Refusing, Following),
   administrationFlowBody, administrationFromFlowBody, administrationReceiptFromFlowBody,
   appendManagerReply, managerFlowCeiling, managerFlowContent)
import Agentic.Manager.Protocol.Command (encoded)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.Protocol.LocalAdmin (AdminFailure (StorageUnavailable))
import Agentic.Manager.Store (CoordinationStore, Transaction, appendCommandRecord, refuseTransaction, storeManagerFlow)
import Agentic.Runtime
  (Actor (Manager, Principal), Authority (LocalAccount), Address (To), Position (..), Record (..), Schema (FlowReceipt), noAbout)
import Control.Monad (unless)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.Word (Word64)
import System.Posix.Types (CUid (..))
import System.Posix.User (getEffectiveUserID)

-- | The sender of an administration record: the local account whose user
-- identifier the channel verified, since
-- 'Agentic.Manager.LocalAdmin.withLocalAdministration' admits only a peer with
-- the effective user identifier of the manager. The channel declares no owner.
localAdministrator :: IO Actor
localAdministrator = do
  CUid uid <- getEffectiveUserID
  pure (Principal (LocalAccount uid Nothing))

-- | The position of an appended administration command record and the ceiling
-- of its log, which the receipt after COMMIT answers.
type Logged = Maybe (Word64, Int64)

-- | Append the synchronized @command@ record of an admitted administration
-- operation from the local account, as the last step before COMMIT. The
-- ceiling is that of the lifetime's log, so the operation takes no
-- configuration lock that it does not already hold. A failed append, or an
-- appended record whose decoded body, sender or address differs from the
-- operation, refuses the operation with 'StorageUnavailable', and the
-- transaction answers the record with a @failure@ record when it rolls back. A
-- lifetime without a manager log, such as offline administration, appends
-- nothing.
recordAdministration :: CoordinationStore -> Actor -> AdministrationBody -> Transaction Logged
recordAdministration store principal command = do
  let total = maybe 0 managerFlowCeiling (storeManagerFlow store)
  appended <- appendCommandRecord total Refusing principal noAbout (administrationFlowBody command)
  case appended of
    Nothing -> pure Nothing
    Just (Left _) -> refuseTransaction StorageUnavailable
    Just (Right (Position position, record, content)) -> do
      unless ((content >>= administrationFromFlowBody) == Right command && recFrom record == principal && recTo record == To Manager)
        (refuseTransaction StorageUnavailable)
      pure (Just (position, total))

-- | After COMMIT, append the response that the operator receives as the
-- receipt that replies to the command record, and return the response decoded
-- from the appended bytes. When the append fails, or the decoded response
-- differs, the original response is returned, and a failed append leaves a gap
-- entry.
recordAdministrationReceipt :: CoordinationStore -> Actor -> Logged -> BS.ByteString -> IO BS.ByteString
recordAdministrationReceipt store principal logged response = case (storeManagerFlow store, logged, decodeStrictValue response) of
  (Just manager, Just (position, total), Right value) -> do
    appended <- appendManagerReply manager total Following FlowReceipt (Position position) Manager (To principal) noAbout value
    case appended of
      Left _ -> pure response
      Right (_, record) -> do
        decoded <- (>>= administrationReceiptFromFlowBody) <$> managerFlowContent manager record
        pure $ case decoded of
          Right carried | carried == value -> encoded carried
          _ -> response
  _ -> pure response
