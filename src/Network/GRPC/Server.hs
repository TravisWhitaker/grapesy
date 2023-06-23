{-# LANGUAGE OverloadedStrings #-}

module Network.GRPC.Server (
    -- * Server proper
    ServerParams(..)
  , withServer

    -- * Handlers
  , Call       -- opaque
  , RpcHandler -- opaque
  , Handler.mkRpcHandler
  , Handler.handlerMetadata

    -- * Ongoing calls
  , CustomMetadata(..)
  , StreamElem(..)
  , recvInput
  , sendOutput

    -- ** Protocol specific wrappers
  , recvFinalInput
  , recvNextInput
  , sendFinalOutput
  , sendNextOutput
  , sendTrailers

    -- * Common serialization formats
  , Protobuf
  ) where

import Control.Exception
import Network.HTTP2.Server qualified as HTTP2

import Network.GRPC.Common.Exceptions
import Network.GRPC.Common.StreamElem (StreamElem(..))
import Network.GRPC.Server.Call
import Network.GRPC.Server.Connection (Connection, withConnection)
import Network.GRPC.Server.Connection qualified as Connection
import Network.GRPC.Server.Context (ServerParams)
import Network.GRPC.Server.Context qualified as Context
import Network.GRPC.Server.Handler (RpcHandler(..))
import Network.GRPC.Server.Handler qualified as Handler
import Network.GRPC.Spec
import Network.GRPC.Spec.CustomMetadata
import Network.GRPC.Spec.PseudoHeaders
import Network.GRPC.Spec.RPC.Protobuf (Protobuf)

{-------------------------------------------------------------------------------
  Server proper
-------------------------------------------------------------------------------}

-- | Construct server
--
-- The server can be run using the standard infrastructure offered by the
-- @http2@ package, but "Network.GRPC.Server.Run" provides some convenience
-- functions.
withServer :: ServerParams -> [RpcHandler IO] -> (HTTP2.Server -> IO a) -> IO a
withServer params handlers k = do
    Context.withContext params $ \ctxt ->
      k $ withConnection ctxt $
        handleRequest (Handler.constructMap handlers)

handleRequest :: Handler.Map IO -> Connection -> IO ()
handleRequest handlers conn = do
    -- TODO: Proper "Apache style" logging (in addition to the debug logging)
    print path

    RpcHandler{
        handlerMetadata
      , handlerRun
      } <- getHandler handlers path
    mCall :: Either SomeException (Call rpc) <-
      try $ acceptCall conn handlerMetadata

    case mCall of
      Right call -> do
        -- TODO: Timeouts
        --
        -- Wait-for-ready semantics makes this more complicated, maybe.
        -- See example in the grpc-repo (python/wait_for_ready).

        mErr :: Either SomeException () <- try $ handlerRun call
        case mErr of
          Right () -> return ()
          Left err -> do
            -- TODO: We need to think hard about error handling.
            --
            -- o It should be possible to throw a specific gRPC non-OK status
            --   (i.e., we should catch GrpcException and treat it special)
            -- o We need to think about how streaming works with trailers, if
            --   streaming goes wrong halfway
            -- o We need to consider security concerns here, too
            --   (exceptions can leak sensitive data)
            --
            -- gRPC error responses must make use of the gRPC Trailers-Only case
            -- according to the spec.
            putStrLn $ "Uncaught exception: " ++ show err
            putStrLn "(TODO: We need a proper handler here.)"
      Left err -> do
        putStrLn $ "Uncaught exception during acceptCall: " ++ show err
        putStrLn "(TODO: We need a proper handler here.)"
  where
    path :: Path
    path = Connection.path conn

{-------------------------------------------------------------------------------
  Get handler for the request
-------------------------------------------------------------------------------}

getHandler :: Handler.Map m -> Path -> IO (RpcHandler m)
getHandler handlers path = do
    case Handler.lookup path handlers of
      Nothing -> throwIO $ grpcUnimplemented path
      Just h  -> return h

grpcUnimplemented :: Path -> GrpcException
grpcUnimplemented path = GrpcException {
      grpcError         = GrpcUnimplemented
    , grpcErrorMessage  = Just $ mconcat [
                                "Method "
                              , pathService path
                              , "."
                              , pathMethod path
                              , " not implemented"
                              ]
    , grpcErrorMetadata = []
    }
