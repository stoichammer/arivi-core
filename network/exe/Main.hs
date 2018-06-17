{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import           Arivi.Crypto.Utils.Keys.Signature
import           Arivi.Crypto.Utils.PublicKey.Signature as ACUPS
import           Arivi.Crypto.Utils.PublicKey.Utils
import           Arivi.Env
import           Arivi.Logging
import           Arivi.Network.Connection               (CompleteConnection,
                                                         ConnectionId)
import           Arivi.Network.Instance
import           Arivi.Network.StreamServer
import qualified Arivi.Network.Types                    as ANT (PersonalityType (INITIATOR),
                                                                TransportType (TCP))
import           Control.Concurrent                     (threadDelay)
import           Control.Concurrent.Async
import           Control.Concurrent.STM.TQueue
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.HashTable.IO                      as MutableHashMap (new)
-- import           Arivi.Network.Datagram             (createUDPSocket)
import           Control.Exception
import           Data.ByteString.Lazy                   as BSL (ByteString)
import           Data.ByteString.Lazy.Char8             as BSLC (pack)
import           Data.Time
import           System.Environment                     (getArgs)

type AppM = ReaderT AriviEnv (LoggingT IO)

instance HasEnv AppM where
  getEnv = ask

instance HasAriviNetworkInstance AppM where
  getAriviNetworkInstance = ariviNetworkInstance <$> getEnv

instance HasSecretKey AppM where
  getSecretKey = cryptoEnvSercretKey . ariviCryptoEnv <$> getEnv

instance HasLogging AppM where
  getLoggerChan = loggerChan <$> getEnv

instance HasUDPSocket AppM where
  getUDPSocket = udpSocket <$> getEnv

runAppM :: AriviEnv -> AppM a -> LoggingT IO a
runAppM = flip runReaderT



sender :: SecretKey -> SecretKey -> Int -> Int -> IO ()
sender sk rk n size = do
  tq <- newTQueueIO :: IO LogChan
  -- sock <- createUDPSocket "127.0.0.1" (envPort mkAriviEnv)
  mutableConnectionHashMap <- MutableHashMap.new
                                    :: IO (HashTable ConnectionId CompleteConnection)
  env' <- mkAriviEnv
  let env = env' { ariviCryptoEnv = CryptoEnv sk
                 , loggerChan = tq
                 -- , udpSocket = sock
                 , udpConnectionHashMap = mutableConnectionHashMap
                 }
  runStdoutLoggingT $ runAppM env (do

                                       let ha = "127.0.0.1"
                                       cidOrFail <- openConnection ha 8083 ANT.TCP (generateNodeId rk) ANT.INITIATOR
                                       case cidOrFail of
                                          Left e -> throw e
                                          Right cid -> do
                                            time <- liftIO  getCurrentTime
                                            liftIO $ print time
                                            mapM_ (const (sendMessage cid (a size))) [1..n]
                                            time2 <- liftIO  getCurrentTime
                                            liftIO $ print time2
                                       liftIO $ print "done"
                                   )
receiver :: SecretKey -> IO ()
receiver sk = do
  tq <- newTQueueIO :: IO LogChan
  -- sock <- createUDPSocket "127.0.0.1" (envPort mkAriviEnv)
  mutableConnectionHashMap1 <- MutableHashMap.new
                                    :: IO (HashTable ConnectionId CompleteConnection)
  env' <- mkAriviEnv
  let env = env' { ariviCryptoEnv = CryptoEnv sk
                 , loggerChan = tq
                 -- , udpSocket = sock
                 , udpConnectionHashMap = mutableConnectionHashMap1
                 }
  runStdoutLoggingT $ runAppM env (
                                       runTCPServer (show (envPort env))
                                  )

initiator :: IO ()
initiator = do
  [size, n] <- getArgs
  let sender_sk = ACUPS.getSecretKey "ssssssssssssssssssssssssssssssss"
      recv_sk = ACUPS.getSecretKey "rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"
  _ <- threadDelay 1000000 >> sender sender_sk recv_sk (read n) (read size)
  threadDelay 1000000000000
  return ()

recipient :: IO ()
recipient = do
  let recv_sk = ACUPS.getSecretKey "rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"
  receiver recv_sk
  threadDelay 1000000000000

main :: IO ()
main = do
  _ <- recipient `concurrently` (threadDelay 1000000 >> initiator)
  return ()

a :: Int -> BSL.ByteString
a n = BSLC.pack (replicate n 'a')
