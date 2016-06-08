{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
{-# OPTIONS_GHC -fno-warn-unused-binds       #-}

import           Control.Concurrent.Async                  (async, wait)
import           Control.Monad                             (forever)
import           Data.ByteString                           (ByteString)
import           Network.GRPC.LowLevel
import qualified Network.GRPC.LowLevel.Server.Unregistered as U

serverMeta :: MetadataMap
serverMeta = [("test_meta", "test_meta_value")]

handler :: ByteString -> MetadataMap -> MethodName
           -> IO (ByteString, MetadataMap, StatusDetails)
handler reqBody _reqMeta _method = do
  --putStrLn $ "Got request for method: " ++ show method
  --putStrLn $ "Got metadata: " ++ show reqMeta
  return (reqBody, serverMeta, StatusDetails "")

unregMain :: IO ()
unregMain = withGRPC $ \grpc -> do
  withServer grpc (ServerConfig "localhost" 50051 []) $ \server -> forever $ do
    result <- U.serverHandleNormalCall server 15 serverMeta handler
    case result of
      Left x -> putStrLn $ "handle call result error: " ++ show x
      Right _ -> return ()

regMain :: IO ()
regMain = withGRPC $ \grpc -> do
  let methods = [(MethodName "/echo.Echo/DoEcho", Normal)]
  withServer grpc (ServerConfig "localhost" 50051 methods) $ \server ->
    forever $ do
      let method = head (registeredMethods server)
      result <- serverHandleNormalCall server method 15 serverMeta $
        \reqBody _reqMeta -> return (reqBody, serverMeta, serverMeta,
                                     StatusDetails "")
      case result of
        Left x -> putStrLn $ "registered call result error: " ++ show x
        Right _ -> return ()

-- | loop to fork n times
regLoop :: Server -> RegisteredMethod -> IO ()
regLoop server method = forever $ do
  result <- serverHandleNormalCall server method 15 serverMeta $
    \reqBody _reqMeta -> return (reqBody, serverMeta, serverMeta,
                                 StatusDetails "")
  case result of
    Left x -> putStrLn $ "registered call result error: " ++ show x
    Right _ -> return ()

regMainThreaded :: IO ()
regMainThreaded = do
  withGRPC $ \grpc -> do
    let methods = [(MethodName "/echo.Echo/DoEcho", Normal)]
    withServer grpc (ServerConfig "localhost" 50051 methods) $ \server -> do
      let method = head (registeredMethods server)
      tid1 <- async $ regLoop server method
      tid2 <- async $ regLoop server method
      wait tid1
      wait tid2
      return ()

main :: IO ()
main = regMainThreaded
