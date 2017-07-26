{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module API.QueueUtils where

import Control.Lens hiding ((.=))
import Control.Monad.IO.Class
import Control.Monad.Reader
import Data.Foldable (for_)
import Data.ProtoLens.Encoding
import Galley.Aws
import Data.Int
import Data.Id
import Data.ByteString.Conversion (toByteString')
import Data.Text (Text)
import System.Logger.Class
import Network.HTTP.Client.OpenSSL
import Network.HTTP.Client
import OpenSSL.Session as Ssl
import Galley.Options (JournalOpts (..))
import Test.Tasty.HUnit

import qualified Galley.Aws as Aws
import qualified System.Logger as L
import qualified Data.ByteString.Base64 as B64
import qualified Network.AWS as AWS
import qualified Network.AWS.SQS as SQS
import qualified Proto.Galley.Intra.TeamEvents as E
import qualified Data.Text.Encoding as Text
import qualified OpenSSL.X509.SystemStore as Ssl

assertQueue :: MonadIO m => Maybe Aws.Env -> (E.TeamEvent -> IO ()) -> m ()
assertQueue (Just env) check = liftIO $ Aws.execute env $ fetchMessage check
assertQueue Nothing _ = return ()

assertQueueEmpty :: MonadIO m => Maybe Aws.Env -> m ()
assertQueueEmpty (Just env) = liftIO $ Aws.execute env ensureNoMessages
assertQueueEmpty Nothing = return ()

tCreate :: E.TeamEvent -> IO ()
tCreate e = do
    assertEqual "eventType" E.TeamEvent'TEAM_CREATE (e^.E.eventType)
    assertEqual "count" 1 (e^.E.eventData^.E.memberCount)

tDelete :: E.TeamEvent -> IO ()
tDelete e = assertEqual "eventType" E.TeamEvent'TEAM_DELETE (e^.E.eventType)

tUpdate :: Int32 -> [UserId] -> E.TeamEvent -> IO ()
tUpdate c uids e = do
    assertEqual "eventType" E.TeamEvent'TEAM_UPDATE (e^.E.eventType)
    assertEqual "count" c (e^.E.eventData^.E.memberCount)
    assertEqual "billing users" (toByteString' <$> uids) (e^.E.eventData^.E.billingUser)

ensureNoMessages :: Amazon ()
ensureNoMessages = do
    QueueUrl url <- view eventQueue
    msgs <- view SQS.rmrsMessages <$> AWS.send (receive url)
    liftIO $ assertEqual "length" 0 (length msgs)

fetchMessage :: (E.TeamEvent -> IO ()) -> Amazon ()
fetchMessage callback = do
    QueueUrl url <- view eventQueue
    msgs <- view SQS.rmrsMessages <$> AWS.send (receive url)
    liftIO $ assertEqual "expected 1 message" 1 (length msgs)
    mapM_ (onMessage url callback) msgs

receive :: Text -> SQS.ReceiveMessage
receive url = SQS.receiveMessage url
                & set SQS.rmWaitTimeSeconds (Just 5)
                . set SQS.rmMaxNumberOfMessages (Just 1)

onMessage :: Text -> (E.TeamEvent -> IO()) -> SQS.Message -> Amazon ()
onMessage url callback m =
  case (>>= decodeMessage) . B64.decode . Text.encodeUtf8 <$> (m^.SQS.mBody) of
      Just (Right e) -> do
          debug $ msg $ val "SQS event received"
          liftIO $ callback e
          for_ (m ^. SQS.mReceiptHandle) (void . AWS.send . SQS.deleteMessage url)
      _ -> err . msg $ val "Failed to parse SQS event"

initHttpManager :: IO Manager
initHttpManager = do
    ctx <- Ssl.context
    Ssl.contextSetVerificationMode ctx $ Ssl.VerifyPeer True True Nothing
    Ssl.contextAddOption ctx SSL_OP_NO_SSLv2
    Ssl.contextAddOption ctx SSL_OP_NO_SSLv3
    Ssl.contextAddOption ctx SSL_OP_NO_TLSv1
    Ssl.contextSetCiphers ctx rsaCiphers
    Ssl.contextLoadSystemCerts ctx
    newManager (opensslManagerSettings ctx)
        { managerResponseTimeout     = responseTimeoutMicro 10000000
        , managerConnCount           = 100
        , managerIdleConnectionCount = 300
        }

mkAWSEnv :: Text -> IO Aws.Env
mkAWSEnv queue = do
    l   <- L.new $ L.setOutput L.StdOut . L.setFormat Nothing $ L.defSettings
    mgr <- initHttpManager
    let opts = JournalOpts queue AWS.Ireland
    Aws.mkEnv l mgr opts
