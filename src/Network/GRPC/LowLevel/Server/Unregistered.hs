{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.LowLevel.Server.Unregistered where

import           Control.Exception                                  (finally)
import           Data.ByteString                                    (ByteString)
import           Network.GRPC.LowLevel.Call                         (MethodName)
import           Network.GRPC.LowLevel.Call.Unregistered
import           Network.GRPC.LowLevel.CompletionQueue              (TimeoutSeconds)
import           Network.GRPC.LowLevel.CompletionQueue.Unregistered (serverRequestCall)
import           Network.GRPC.LowLevel.GRPC
import           Network.GRPC.LowLevel.Op                           (OpRecvResult (..), runOps)
import           Network.GRPC.LowLevel.Server                       (Server (..),
                                                                     serverOpsGetNormalCall,
                                                                     serverOpsSendNormalResponse)
import qualified Network.GRPC.Unsafe.Op                             as C

serverCreateCall :: Server -> TimeoutSeconds
                    -> IO (Either GRPCIOError ServerCall)
serverCreateCall Server{..} timeLimit =
  serverRequestCall internalServer serverCQ timeLimit

withServerCall :: Server -> TimeoutSeconds
                  -> (ServerCall -> IO (Either GRPCIOError a))
                  -> IO (Either GRPCIOError a)
withServerCall server timeout f = do
  createResult <- serverCreateCall server timeout
  case createResult of
    Left x -> return $ Left x
    Right call -> f call `finally` logDestroy call
      where logDestroy c = grpcDebug "withServerCall: destroying."
                           >> destroyServerCall c

-- | A handler for an unregistered server call; bytestring arguments are the
-- request body and response body respectively.
type ServerHandler
  =  ByteString -> MetadataMap -> MethodName
  -> IO (ByteString, MetadataMap, StatusDetails)

-- | Handle one unregistered call.
serverHandleNormalCall :: Server
                       -> TimeoutSeconds
                       -> MetadataMap -- ^ Initial server metadata.
                       -> ServerHandler
                       -> IO (Either GRPCIOError ())
serverHandleNormalCall s@Server{..} timeLimit srvMetadata f = do
  withServerCall s timeLimit $ \call -> do
    grpcDebug "serverHandleNormalCall(U): starting batch."
    let recvOps = serverOpsGetNormalCall srvMetadata
        call'   = unServerCall call
    opResults <- runOps call' serverCQ recvOps timeLimit
    case opResults of
      Left x -> do grpcDebug "serverHandleNormalCall(U): ops failed; aborting"
                   return $ Left x
      Right [OpRecvMessageResult (Just body)] -> do
        requestMeta <- serverCallGetMetadata call
        grpcDebug $ "got client metadata: " ++ show requestMeta
        methodName <- serverCallGetMethodName call
        hostName <- serverCallGetHost call
        grpcDebug $ "call_details host is: " ++ show hostName
        (respBody, respMetadata, details) <- f body requestMeta methodName
        let status = C.GrpcStatusOk
        let respOps = serverOpsSendNormalResponse
                        respBody respMetadata status details
        respOpsResults <- runOps call' serverCQ respOps timeLimit
        case respOpsResults of
          Left x -> do grpcDebug "serverHandleNormalCall(U): resp failed."
                       return $ Left x
          Right _ -> grpcDebug "serverHandleNormalCall(U): ops done."
                     >> return (Right ())
      x -> error $ "impossible pattern match: " ++ show x
