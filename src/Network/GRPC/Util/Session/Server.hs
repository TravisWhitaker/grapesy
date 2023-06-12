-- | Node with server role (i.e., its peer is a client)
module Network.GRPC.Util.Session.Server (
    ConnectionToClient(..)
  , initiateResponse
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Tracer
import Network.HTTP2.Server qualified as Server

import Network.GRPC.Util.HTTP2
import Network.GRPC.Util.Session.API
import Network.GRPC.Util.Session.Channel
import Network.GRPC.Util.Thread

{-------------------------------------------------------------------------------
  Connection
-------------------------------------------------------------------------------}

-- | Connection to the client, as provided by @http2@
data ConnectionToClient = ConnectionToClient {
      request :: Server.Request
    , respond :: Server.Response -> IO ()
    }

{-------------------------------------------------------------------------------
  Initiate response
-------------------------------------------------------------------------------}

-- | Initiate response to the client
initiateResponse :: forall sess.
     AcceptSession sess
  => sess
  -> Tracer IO (DebugMsg sess)
  -> ConnectionToClient
  -> (InboundHeaders sess -> IO (OutboundHeaders sess))
  -> IO (Channel sess)
initiateResponse sess tracer conn mkOutboundHeaders = do
    channel <- initChannel

    let requestHeaders = fromHeaderTable $ Server.requestHeaders (request conn)
    requestMethod <- case Server.requestMethod (request conn) of
                       Just x  -> return x
                       Nothing -> throwIO PeerMissingPseudoHeaderMethod
    requestPath   <- case Server.requestPath (request conn) of
                       Just x  -> return x
                       Nothing -> throwIO PeerMissingPseudoHeaderPath
    let requestInfo = RequestInfo {requestHeaders, requestMethod, requestPath}

    inboundHeaders <- parseRequestInfo sess requestInfo

    void $ forkIO $
      threadBody (channelInbound channel) initInbound $ \st -> do
        atomically $ putTMVar (channelInboundHeaders st) inboundHeaders
        if Server.requestBodySize (request conn)  == Just 0 then
          processInboundTrailers sess tracer st requestHeaders
        else
          recvMessageLoop
            sess
            tracer
            st
            (Server.getRequestBodyChunk (request conn))
            (maybe [] fromHeaderTable <$>
              Server.getRequestTrailers (request conn))

    outboundHeaders <- mkOutboundHeaders inboundHeaders
    responseInfo    <- buildResponseInfo sess outboundHeaders

    let resp :: OutboundState sess -> Server.Response
        resp st = setResponseTrailers sess channel $
          Server.responseStreaming
                        (responseStatus  responseInfo)
                        (responseHeaders responseInfo)
                      $ \write flush ->
            sendMessageLoop sess tracer st write flush

    void $ forkIO $
      threadBody (channelOutbound channel) initOutbound $ \st -> do
        atomically $ putTMVar (channelOutboundHeaders st) outboundHeaders
        respond conn $ resp st

    return channel

{-------------------------------------------------------------------------------
  Auxiliary http2
-------------------------------------------------------------------------------}

setResponseTrailers ::
     IsSession sess
  => sess
  -> Channel sess
  -> Server.Response -> Server.Response
setResponseTrailers sess channel resp =
    Server.setResponseTrailersMaker resp $
      processOutboundTrailers sess channel