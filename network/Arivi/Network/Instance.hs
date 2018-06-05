{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TemplateHaskell       #-}

module Arivi.Network.Instance
(
NetworkConfig (..),
-- getAriviInstance ,
-- runAriviInstance ,
NetworkHandle (..),
AriviNetworkInstance (..),
connectionMap,
mkAriviNetworkInstance,
openConnection,
sendMessage,
closeConnection
, lookupCId
) where

import           Arivi.Env
import           Arivi.Logging
import           Arivi.Network.Connection             as Conn (Connection (..),
                                                               makeConnectionId)
import           Arivi.Network.ConnectionHandler      (readHandshakeRespSock)
import qualified Arivi.Network.FSM                    as FSM
import           Arivi.Network.Handshake
import           Arivi.Network.StreamClient
import           Arivi.Network.Types                  as ANT (ConnectionId,
                                                              Event (..),
                                                              NodeId,
                                                              OutboundFragment,
                                                              Parcel,
                                                              Payload (..),
                                                              PersonalityType,
                                                              TransportType (..))
import           Arivi.Utils.Exception
import           Control.Concurrent                   (threadDelay)
import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.Killable          (kill)
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TChan         (TChan)
import           Control.Exception                    (try)
import           Control.Monad.Reader
import           Control.Monad.STM                    (atomically)
import           Crypto.PubKey.Ed25519                (SecretKey)
import           Data.ByteString.Lazy
import           Data.HashMap.Strict                  as HM
import           Data.Maybe                           (fromMaybe)
import           Debug.Trace
import           Network.Socket
import qualified System.Timer.Updatable               as Timer (Delay, parallel)


-- | Strcuture to hold the arivi configurations can also contain more
--   parameters but for now just contain 3
data NetworkConfig    = NetworkConfig {
                        hostip  :: String
                    ,   udpport :: String
                    ,   tcpPort :: String
                    -- , TODO   transportType :: TransportType and only one port
                    } deriving (Show)

-- | Strcuture which holds all the information about a running arivi Instance
--   and can be passed around to different functions to differentiate betweeen
--   different instances of arivi.
newtype NetworkHandle = NetworkHandle { ariviUDPSock :: (Socket,SockAddr) }
                    -- ,   ariviTCPSock :: (Socket,SockAddr)
                    -- ,   udpThread    :: MVar ThreadId
                    -- ,   tcpThread    :: MVar ThreadId
                    -- ,
                    -- registry     :: MVar MP.ServiceRegistry


doEncryptedHandshake :: Conn.Connection -> SecretKey -> IO Conn.Connection
doEncryptedHandshake connection sk = do
    (serialisedParcel, updatedConn) <- initiatorHandshake sk connection
    sendFrame (Conn.socket updatedConn) (createFrame serialisedParcel)
    hsRespParcel <- readHandshakeRespSock (Conn.socket connection) sk
    traceShow hsRespParcel (return ())
    return $ receiveHandshakeResponse connection hsRespParcel

openConnection :: (HasAriviNetworkInstance m,
                   HasSecretKey m,
                   HasLogging m,
                   Forall (Pure m))
               => HostName
               -> PortNumber
               -> TransportType
               -> NodeId
               -> PersonalityType
               -> m (Either AriviException ANT.ConnectionId)
openConnection addr port tt rnid pType = do
  ariviInstance <- getAriviNetworkInstance
  let cId = makeConnectionId addr port tt
  let tv = connectionMap ariviInstance
  hm <- liftIO $ readTVarIO tv
  case HM.lookup cId hm of
    Just conn -> return $ Right cId
    Nothing   ->
                do
                  sk <- getSecretKey
                  socket <- liftIO $ createSocket addr (read (show port)) tt
                  reassemblyChan <- liftIO (newTChanIO :: IO (TChan Parcel))
                  p2pMsgTChan <- liftIO (newTChanIO :: IO (TChan ByteString))
                  let connection = Connection {connectionId = cId, remoteNodeId = rnid, ipAddress = addr, port = port, transportType = tt, personalityType = pType, Conn.socket = socket, reassemblyTChan = reassemblyChan, p2pMessageTChan = p2pMsgTChan}
                  res <- liftIO $ try $ doEncryptedHandshake connection sk
                  case res of
                    Left e -> return $ Left e
                    Right updatedConn ->
                      do
                        liftIO $ atomically $ modifyTVar tv (HM.insert cId updatedConn)
                        return $ Right cId

sendMessage :: (HasAriviNetworkInstance m)
            => ANT.ConnectionId
            -> ByteString
            -> m ()
sendMessage cId msg = do
  conn <- lookupCId cId
  liftIO $ atomically $ writeTChan (eventTChan conn) (SendDataEvent (Payload msg))

closeConnection :: (HasAriviNetworkInstance m)
                => ANT.ConnectionId
                -> m ()
closeConnection cId = do
  ariviInstance <- getAriviNetworkInstance
  let tv = connectionMap ariviInstance
  liftIO $ atomically $ modifyTVar tv (HM.delete cId)


lookupCId :: (HasAriviNetworkInstance m)
          => ANT.ConnectionId
          -> m Connection
lookupCId cId = do
  ariviInstance <- getAriviNetworkInstance
  let tv = connectionMap ariviInstance
  hmap <- liftIO $ readTVarIO tv
  return $ fromMaybe (error "Something terrible happened! You have been warned not to enter the forbidden lands") (HM.lookup cId hmap)
